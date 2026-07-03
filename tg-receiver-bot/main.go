package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gotd/td/session"
	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/downloader"
	"github.com/gotd/td/telegram/message"
	"github.com/gotd/td/tg"
)

var (
	apiID           int
	apiHash         string
	botToken        string
	allowedChat     int64
	downloadDir     string
	downloadWorkers int
)

type downloadedFile struct {
	tmpPath   string
	finalPath string
	sizeBytes int64
	fileName  string
}

var (
	stateMu               sync.Mutex
	downloaded            []downloadedFile
	doneReceived          bool
	doneEntities          tg.Entities
	doneUpdate            *tg.UpdateNewMessage
	currentDownloadActive bool
	globalCancel          context.CancelFunc
)

type downloadTask struct {
	message   *tg.Message
	update    *tg.UpdateNewMessage
	entities  tg.Entities
	fileName  string
	sizeBytes int64
	tmpDest   string
	finalDest string
	location  tg.InputFileLocationClass
}

type configStruct struct {
	APIID           string `json:"API_ID"`
	APIHash         string `json:"API_HASH"`
	BotToken        string `json:"BOT_TOKEN"`
	AllowedChat     string `json:"ALLOWED_CHAT"`
	DownloadDir     string `json:"DOWNLOAD_DIR"`
	DownloadWorkers string `json:"DOWNLOAD_WORKERS"`
}

func loadConfigString(b64Str string) error {
	decoded, err := base64.StdEncoding.DecodeString(b64Str)
	if err != nil {
		return err
	}
	var cfg configStruct
	if err := json.Unmarshal(decoded, &cfg); err != nil {
		return err
	}
	if cfg.APIID != "" {
		os.Setenv("API_ID", cfg.APIID)
	}
	if cfg.APIHash != "" {
		os.Setenv("API_HASH", cfg.APIHash)
	}
	if cfg.BotToken != "" {
		os.Setenv("BOT_TOKEN", cfg.BotToken)
	}
	if cfg.AllowedChat != "" {
		os.Setenv("ALLOWED_CHAT", cfg.AllowedChat)
	}
	if cfg.DownloadDir != "" {
		os.Setenv("DOWNLOAD_DIR", cfg.DownloadDir)
	}
	if cfg.DownloadWorkers != "" {
		os.Setenv("DOWNLOAD_WORKERS", cfg.DownloadWorkers)
	}
	return nil
}

func printConfigString() {
	cfg := configStruct{
		APIID:           strconv.Itoa(apiID),
		APIHash:         apiHash,
		BotToken:        botToken,
		AllowedChat:     strconv.FormatInt(allowedChat, 10),
		DownloadDir:     downloadDir,
		DownloadWorkers: strconv.Itoa(downloadWorkers),
	}
	data, err := json.Marshal(cfg)
	if err == nil {
		b64Str := base64.StdEncoding.EncodeToString(data)
		fmt.Println("")
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println("  Your config string (save this for next time):")
		fmt.Println("")
		fmt.Printf("  %s\n", b64Str)
		fmt.Println("")
		fmt.Println("  Next run:")
		fmt.Printf("  bash <(curl -Ls https://script.s7net.ir/tg-receiver.sh) --config %s\n", b64Str)
		fmt.Println("")
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println("")
	}
}

func main() {
	log.Println("Starting Telegram Backup Downloader Bot (Go version)...")

	// Parse flags
	var configB64 string
	flag.StringVar(&configB64, "config", "", "base64 encoded JSON configuration string")
	flag.Parse()

	if configB64 != "" {
		if err := loadConfigString(configB64); err != nil {
			log.Fatalf("ERROR: Failed to load config from base64 string: %v", err)
		}
	}

	// Parse environment variables
	var err error
	apiIDStr := os.Getenv("API_ID")
	if apiIDStr == "" {
		log.Fatal("ERROR: Missing API_ID environment variable")
	}
	apiID, err = strconv.Atoi(apiIDStr)
	if err != nil {
		log.Fatalf("ERROR: API_ID must be numeric: %v", err)
	}

	apiHash = os.Getenv("API_HASH")
	if apiHash == "" {
		log.Fatal("ERROR: Missing API_HASH environment variable")
	}

	botToken = os.Getenv("BOT_TOKEN")
	if botToken == "" {
		log.Fatal("ERROR: Missing BOT_TOKEN environment variable")
	}

	allowedChatStr := os.Getenv("ALLOWED_CHAT")
	if allowedChatStr == "" {
		log.Fatal("ERROR: Missing ALLOWED_CHAT environment variable")
	}
	allowedChat, err = strconv.ParseInt(allowedChatStr, 10, 64)
	if err != nil {
		log.Fatalf("ERROR: ALLOWED_CHAT must be numeric: %v", err)
	}

	downloadDir = os.Getenv("DOWNLOAD_DIR")
	if downloadDir == "" {
		downloadDir = "./downloads"
	}

	workersStr := os.Getenv("DOWNLOAD_WORKERS")
	if workersStr != "" {
		downloadWorkers, err = strconv.Atoi(workersStr)
		if err != nil {
			log.Fatalf("ERROR: DOWNLOAD_WORKERS must be numeric: %v", err)
		}
	} else {
		downloadWorkers = 10
	}

	// Create download directory
	if err := os.MkdirAll(downloadDir, 0755); err != nil {
		log.Fatalf("ERROR: Failed to create download directory %s: %v", downloadDir, err)
	}

	// Print config string if it wasn't supplied via flag
	if configB64 == "" {
		printConfigString()
	}

	// Setup context with cancellation and signal handling
	ctx, cancel := context.WithCancel(context.Background())
	globalCancel = cancel
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("Received termination signal, shutting down...")
		cancel()
	}()

	// Setup Temp Directory
	tmpDir, err := os.MkdirTemp("", "tgdl_*")
	if err != nil {
		log.Fatalf("ERROR: Failed to create temp directory: %v", err)
	}
	defer func() {
		log.Println("Cleaning up temporary files...")
		os.RemoveAll(tmpDir)
		log.Println("Done. Your files are in:", downloadDir)
	}()

	// Session file setup
	sessionFile := "tg_downloader_bot.session"
	storage := &session.FileStorage{
		Path: sessionFile,
	}

	// Pre-declare client for closure
	var client *telegram.Client

	// Dispatcher
	dispatcher := tg.NewUpdateDispatcher()
	sender := message.NewSender(nil) // we'll populate this later once client is running

	taskQueue := make(chan downloadTask, 100)

	// Set up the message handler
	dispatcher.OnNewMessage(func(ctx context.Context, entities tg.Entities, u *tg.UpdateNewMessage) error {
		m, ok := u.Message.(*tg.Message)
		if !ok || m.Out {
			return nil
		}

		// Verify allowed chat
		if !matchPeer(m.PeerID, allowedChat) {
			return nil
		}

		// Handle "/done"
		if m.Message != "" && strings.TrimSpace(strings.ToLower(m.Message)) == "/done" {
			stateMu.Lock()
			doneReceived = true
			doneEntities = entities
			doneUpdate = u

			qSize := len(taskQueue)
			if currentDownloadActive {
				qSize++
			}

			if qSize == 0 {
				stateMu.Unlock()
				shutdown(ctx, client.API(), entities, u)
			} else {
				stateMu.Unlock()
				_, _ = sender.Reply(entities, u).Text(ctx, fmt.Sprintf("⏳ Done command received. Waiting for %d remaining download(s) to complete...", qSize))
			}
			return nil
		}

		if m.Media == nil {
			return nil
		}

		stateMu.Lock()
		if doneReceived {
			stateMu.Unlock()
			_, _ = sender.Reply(entities, u).Text(ctx, "⚠️ Bot is shutting down. No new downloads accepted.")
			return nil
		}
		stateMu.Unlock()

		// Parse media location, filename, and size
		var fileName string
		var sizeBytes int64
		var loc tg.InputFileLocationClass

		switch media := m.Media.(type) {
		case *tg.MessageMediaDocument:
			if doc, ok := media.Document.(*tg.Document); ok {
				sizeBytes = doc.Size
				for _, attr := range doc.Attributes {
					if nameAttr, ok := attr.(*tg.DocumentAttributeFilename); ok {
						fileName = nameAttr.FileName
						break
					}
				}
				if fileName == "" {
					fileName = fmt.Sprintf("document_%d", m.ID)
				}
				loc = &tg.InputDocumentFileLocation{
					ID:            doc.ID,
					AccessHash:    doc.AccessHash,
					FileReference: doc.FileReference,
				}
			}
		case *tg.MessageMediaPhoto:
			if photo, ok := media.Photo.(*tg.Photo); ok {
				var largestType string
				if len(photo.Sizes) > 0 {
					largestSize := photo.Sizes[len(photo.Sizes)-1]
					largestType = getPhotoSizeType(largestSize)
					sizeBytes = getPhotoSizeLength(largestSize)
				}
				if largestType == "" {
					largestType = "y"
				}
				fileName = fmt.Sprintf("photo_%d.jpg", m.ID)
				loc = &tg.InputPhotoFileLocation{
					ID:            photo.ID,
					AccessHash:    photo.AccessHash,
					FileReference: photo.FileReference,
					ThumbSize:     largestType,
				}
			}
		}

		if loc == nil {
			return nil
		}

		tmpDest := uniquePath(tmpDir, fileName)
		finalDest := uniquePath(downloadDir, fileName)

		stateMu.Lock()
		pos := len(taskQueue) + 1
		if currentDownloadActive {
			pos++
		}
		stateMu.Unlock()

		taskQueue <- downloadTask{
			message:   m,
			update:    u,
			entities:  entities,
			fileName:  fileName,
			sizeBytes: sizeBytes,
			tmpDest:   tmpDest,
			finalDest: finalDest,
			location:  loc,
		}

		log.Printf("Queued: %s (%s) [Position: %d]", fileName, formatSize(sizeBytes), pos)
		_, err := sender.Reply(entities, u).Text(ctx, fmt.Sprintf("📥 Queued: `%s` (%s) [Position: %d]", fileName, formatSize(sizeBytes), pos))
		return err
	})

	// Create client
	client = telegram.NewClient(apiID, apiHash, telegram.Options{
		SessionStorage: storage,
		UpdateHandler:  dispatcher,
	})

	// Run client logic
	runErr := client.Run(ctx, func(ctx context.Context) error {
		// Set the API reference in the sender
		*sender = *message.NewSender(client.API())

		// Authenticate
		status, err := client.Auth().Status(ctx)
		if err != nil {
			return err
		}

		if !status.Authorized {
			log.Println("Logging in as bot...")
			if _, err := client.Auth().Bot(ctx, botToken); err != nil {
				return fmt.Errorf("bot login failed: %w", err)
			}
		}

		me, err := client.Self(ctx)
		if err != nil {
			return fmt.Errorf("failed to get self: %w", err)
		}

		username := me.Username

		log.Printf("Bot started : @%s", username)
		log.Printf("Allowed chat: %d", allowedChat)
		log.Printf("Temp dir    : %s", tmpDir)
		log.Printf("Output dir  : %s", downloadDir)
		log.Printf("Workers     : %d parallel chunks", downloadWorkers)
		log.Printf("Ready — send files, then /done to stop.")

		// Start background queue worker
		go startQueueWorker(ctx, client.API(), sender, taskQueue)

		// Wait for context to cancel
		<-ctx.Done()
		return nil
	})

	if runErr != nil && !errors.Is(runErr, context.Canceled) {
		log.Fatalf("ERROR: client run error: %v", runErr)
	}
}

func matchPeer(peer tg.PeerClass, allowedChat int64) bool {
	switch p := peer.(type) {
	case *tg.PeerUser:
		return allowedChat > 0 && p.UserID == allowedChat
	case *tg.PeerChat:
		return allowedChat < 0 && -p.ChatID == allowedChat
	case *tg.PeerChannel:
		if allowedChat < 0 {
			str := strconv.FormatInt(allowedChat, 10)
			if strings.HasPrefix(str, "-100") && len(str) > 4 {
				parsed, err := strconv.ParseInt(str[4:], 10, 64)
				if err == nil && parsed == p.ChannelID {
					return true
				}
			}
		}
	}
	return false
}

func getPhotoSizeType(class tg.PhotoSizeClass) string {
	switch s := class.(type) {
	case *tg.PhotoSize:
		return s.Type
	case *tg.PhotoCachedSize:
		return s.Type
	case *tg.PhotoSizeProgressive:
		return s.Type
	case *tg.PhotoSizeEmpty:
		return s.Type
	}
	return ""
}

func getPhotoSizeLength(class tg.PhotoSizeClass) int64 {
	switch s := class.(type) {
	case *tg.PhotoSize:
		return int64(s.Size)
	case *tg.PhotoCachedSize:
		return int64(len(s.Bytes))
	case *tg.PhotoSizeProgressive:
		if len(s.Sizes) > 0 {
			return int64(s.Sizes[len(s.Sizes)-1])
		}
	}
	return 0
}

func uniquePath(dir, name string) string {
	dest := filepath.Join(dir, name)
	if _, err := os.Stat(dest); os.IsNotExist(err) {
		return dest
	}

	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	counter := 1

	for {
		dest = filepath.Join(dir, fmt.Sprintf("%s_%d%s", stem, counter, ext))
		if _, err := os.Stat(dest); os.IsNotExist(err) {
			return dest
		}
		counter++
	}
}

func formatSize(bytes int64) string {
	if bytes == 0 {
		return "unknown size"
	}
	return fmt.Sprintf("%.1f MB", float64(bytes)/1048576)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

type progressWriterAt struct {
	w         io.WriterAt
	total     int64
	written   int64
	fileName  string
	startTime time.Time
}

func (pw *progressWriterAt) WriteAt(p []byte, off int64) (int, error) {
	n, err := pw.w.WriteAt(p, off)
	if err != nil {
		return n, err
	}
	current := atomic.AddInt64(&pw.written, int64(n))
	pw.printProgress(current)
	return n, nil
}

func (pw *progressWriterAt) printProgress(current int64) {
	total := pw.total
	if total <= 0 {
		total = 1
	}
	pct := float64(current) / float64(total) * 100
	elapsed := time.Since(pw.startTime).Seconds()
	if elapsed == 0 {
		elapsed = 0.001
	}
	speed := float64(current) / elapsed

	var speedStr string
	if speed >= 1048576 {
		speedStr = fmt.Sprintf("%.1f MB/s", speed/1048576)
	} else if speed >= 1024 {
		speedStr = fmt.Sprintf("%.0f KB/s", speed/1024)
	} else {
		speedStr = fmt.Sprintf("%.0f B/s", speed)
	}

	var etaStr string
	if speed > 0 && pw.total > current {
		etaSeconds := float64(pw.total-current) / speed
		if etaSeconds < 0 || etaSeconds > 86400 {
			cmdStr := "--:--"
			etaStr = cmdStr
		} else {
			m := int(etaSeconds) / 60
			s := int(etaSeconds) % 60
			etaStr = fmt.Sprintf("%02d:%02d", m, s)
		}
	} else {
		etaStr = "--:--"
	}

	done := int(pct / 5)
	if done > 20 {
		done = 20
	}
	bar := ""
	for i := 0; i < 20; i++ {
		if i < done {
			bar += "█"
		} else {
			bar += "░"
		}
	}

	nameTrunc := pw.fileName
	if len(nameTrunc) > 30 {
		nameTrunc = nameTrunc[:30]
	}
	fmt.Printf("\r  [%s] %5.1f%%  %10s  ETA %s  %-30s", bar, pct, speedStr, etaStr, nameTrunc)
	os.Stdout.Sync()
}

func startQueueWorker(ctx context.Context, api *tg.Client, sender *message.Sender, taskQueue <-chan downloadTask) {
	dl := downloader.NewDownloader()

	for {
		select {
		case <-ctx.Done():
			return
		case task, ok := <-taskQueue:
			if !ok {
				return
			}

			stateMu.Lock()
			currentDownloadActive = true
			stateMu.Unlock()

			err := processDownload(ctx, api, sender, dl, task)
			if err != nil {
				log.Printf("ERROR: Download failed for %s: %v", task.fileName, err)
			}

			stateMu.Lock()
			currentDownloadActive = false

			if doneReceived && len(taskQueue) == 0 {
				stateMu.Unlock()
				shutdown(ctx, api, doneEntities, doneUpdate)
				return
			}
			stateMu.Unlock()
		}
	}
}

func processDownload(ctx context.Context, api *tg.Client, sender *message.Sender, dl *downloader.Downloader, task downloadTask) error {
	sizeStr := formatSize(task.sizeBytes)
	log.Printf("Downloading: %s  (%s)", task.fileName, sizeStr)

	// Send downloading status update
	statusText := fmt.Sprintf("⬇️ Downloading: `%s`  (%s)", task.fileName, sizeStr)
	_, err := sender.Reply(task.entities, task.update).Text(ctx, statusText)
	if err != nil {
		log.Printf("Warning: failed to send downloading status: %v", err)
	}

	t0 := time.Now()

	// Ensure temp directory exists
	if err := os.MkdirAll(filepath.Dir(task.tmpDest), 0755); err != nil {
		return fmt.Errorf("failed to create temp path: %w", err)
	}

	tmpFile, err := os.Create(task.tmpDest)
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	defer tmpFile.Close()

	pw := &progressWriterAt{
		w:         tmpFile,
		total:     task.sizeBytes,
		written:   0,
		fileName:  task.fileName,
		startTime: t0,
	}

	// Download
	_, err = dl.Download(api, task.location).
		WithThreads(downloadWorkers).
		Parallel(ctx, pw)

	fmt.Println() // Print newline after progress bar

	if err != nil {
		failText := fmt.Sprintf("❌ Failed to download `%s`: %v", task.fileName, err)
		_, _ = sender.Reply(task.entities, task.update).Text(ctx, failText)
		return fmt.Errorf("download parallel error: %w", err)
	}

	elapsed := time.Since(t0).Seconds()
	if elapsed == 0 {
		elapsed = 0.001
	}

	fi, err := os.Stat(task.tmpDest)
	var finalBytes int64
	if err == nil {
		finalBytes = fi.Size()
	} else {
		finalBytes = task.sizeBytes
	}

	finalMB := float64(finalBytes) / 1048576
	avgSpeed := finalMB / elapsed

	log.Printf("Finished: %s  (%.1f MB in %.1fs — avg %.1f MB/s)", task.fileName, finalMB, elapsed, avgSpeed)

	successText := fmt.Sprintf("✅ `%s` — %.1f MB in %.0fs (%.1f MB/s avg)\nWill be moved to final location on /done",
		task.fileName, finalMB, elapsed, avgSpeed)
	_, err = sender.Reply(task.entities, task.update).Text(ctx, successText)
	if err != nil {
		log.Printf("Warning: failed to send success notification: %v", err)
	}

	stateMu.Lock()
	downloaded = append(downloaded, downloadedFile{
		tmpPath:   task.tmpDest,
		finalPath: task.finalDest,
		sizeBytes: finalBytes,
		fileName:  task.fileName,
	})
	stateMu.Unlock()

	return nil
}

func shutdown(ctx context.Context, api *tg.Client, entities tg.Entities, u *tg.UpdateNewMessage) {
	stateMu.Lock()
	defer stateMu.Unlock()

	log.Printf("Moving %d file(s) to %s ...", len(downloaded), downloadDir)

	var moved []string
	for _, file := range downloaded {
		if _, err := os.Stat(file.tmpPath); err == nil {
			_ = os.MkdirAll(filepath.Dir(file.finalPath), 0755)
			err = os.Rename(file.tmpPath, file.finalPath)
			if err != nil {
				err = copyFile(file.tmpPath, file.finalPath)
				if err == nil {
					_ = os.Remove(file.tmpPath)
				}
			}
			if err == nil {
				moved = append(moved, file.fileName)
				log.Printf("  → %s", file.fileName)
			} else {
				log.Printf("ERROR: Failed to move file %s to final path: %v", file.fileName, err)
			}
		}
	}

	summary := "  (none)"
	if len(moved) > 0 {
		var sb strings.Builder
		for _, name := range moved {
			var sz int64
			for _, f := range downloaded {
				if f.fileName == name {
					sz = f.sizeBytes
					break
				}
			}
			sb.WriteString(fmt.Sprintf("  • %s  (%.1f MB)\n", name, float64(sz)/1048576))
		}
		summary = strings.TrimSuffix(sb.String(), "\n")
	}

	msgText := fmt.Sprintf("✅ Done! %d file(s) saved to:\n`%s`\n\n%s\n\n🛑 Shutting down.", len(moved), downloadDir, summary)
	sender := message.NewSender(api)
	_, _ = sender.Reply(entities, u).Text(ctx, msgText)

	log.Println("/done — shutting down.")
	if globalCancel != nil {
		globalCancel()
	}
}
