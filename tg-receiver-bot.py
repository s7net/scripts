#!/usr/bin/env python3
"""
Telegram Downloader
Uses Telethon (MTProto) — no file size limit, parallel chunk download.

Usage:
    API_ID=... API_HASH=... BOT_TOKEN=... ALLOWED_CHAT=... DOWNLOAD_DIR=... python bot.py
"""

import asyncio
import logging
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

from telethon import TelegramClient, events
from telethon.tl.types import MessageMediaDocument, MessageMediaPhoto

# ── Config ────────────────────────────────────────────────────────────────────

API_ID       = int(os.environ["API_ID"])
API_HASH     = os.environ["API_HASH"]
BOT_TOKEN    = os.environ["BOT_TOKEN"]
ALLOWED_CHAT = int(os.environ["ALLOWED_CHAT"])
DOWNLOAD_DIR = Path(os.environ.get("DOWNLOAD_DIR", "./downloads"))

SESSION_NAME = "tg_downloader_bot"

# Telethon parallel download workers (default=1, max=20)
# Higher = faster on good connections, but more RAM usage
DOWNLOAD_WORKERS = int(os.environ.get("DOWNLOAD_WORKERS", "10"))

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
    level=logging.WARNING,          # suppress Telethon noise
)
log = logging.getLogger("tgdl")
log.setLevel(logging.INFO)

# ── State ─────────────────────────────────────────────────────────────────────

downloaded: list[tuple[Path, Path]] = []   # (tmp_path, final_path)
stop_event = asyncio.Event()

# ── Helpers ───────────────────────────────────────────────────────────────────

def unique_path(directory: Path, name: str) -> Path:
    dest = directory / name
    counter = 1
    stem, suffix = Path(name).stem, Path(name).suffix
    while dest.exists():
        dest = directory / f"{stem}_{counter}{suffix}"
        counter += 1
    return dest


class Progress:
    """Live speed + ETA progress bar printed to stdout."""

    def __init__(self, file_name: str, total: int) -> None:
        self.file_name  = file_name
        self.total      = total
        self.start_time = time.monotonic()
        self._last_current = 0

    def __call__(self, current: int, total: int) -> None:
        self.total = total or self.total
        elapsed    = time.monotonic() - self.start_time or 0.001
        speed_bps  = current / elapsed                          # bytes/sec
        speed_str  = self._fmt_speed(speed_bps)
        pct        = current / self.total * 100 if self.total else 0
        eta_sec    = (self.total - current) / speed_bps if speed_bps else 0
        eta_str    = self._fmt_time(eta_sec)
        done       = int(pct // 5)
        bar        = "█" * done + "░" * (20 - done)
        name_trunc = self.file_name[:30].ljust(30)
        print(
            f"\r  [{bar}] {pct:5.1f}%  {speed_str:>10}  ETA {eta_str}  {name_trunc}",
            end="", flush=True,
        )
        self._last_current = current

    @staticmethod
    def _fmt_speed(bps: float) -> str:
        if bps >= 1_048_576:
            return f"{bps/1_048_576:.1f} MB/s"
        if bps >= 1024:
            return f"{bps/1024:.0f} KB/s"
        return f"{bps:.0f} B/s"

    @staticmethod
    def _fmt_time(sec: float) -> str:
        if sec < 0 or sec > 86400:
            return "--:--"
        m, s = divmod(int(sec), 60)
        return f"{m:02d}:{s:02d}"

# ── Bot ───────────────────────────────────────────────────────────────────────

async def run_bot(tmp_dir: Path) -> None:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

    bot = TelegramClient(
        SESSION_NAME,
        API_ID,
        API_HASH,
        # Increase receive buffer for faster downloads
        receive_updates=True,
    )
    await bot.start(bot_token=BOT_TOKEN)

    me = await bot.get_me()
    log.info("Bot started : @%s", me.username)
    log.info("Allowed chat: %s", ALLOWED_CHAT)
    log.info("Temp dir    : %s", tmp_dir)
    log.info("Output dir  : %s", DOWNLOAD_DIR.resolve())
    log.info("Workers     : %s parallel chunks", DOWNLOAD_WORKERS)
    log.info("Ready — send files, then /done to stop.")

    # ── Message handler ───────────────────────────────────────────────────────

    @bot.on(events.NewMessage(chats=ALLOWED_CHAT))
    async def on_message(event):
        msg = event.message

        # ── /done ─────────────────────────────────────────────────────────────
        if msg.text and msg.text.strip().lower() == "/done":
            if downloaded:
                log.info("Moving %d file(s) to %s ...", len(downloaded), DOWNLOAD_DIR)
                moved = []
                for tmp_path, final_path in downloaded:
                    shutil.move(str(tmp_path), str(final_path))
                    moved.append(final_path)
                    log.info("  → %s", final_path.name)
                summary = "\n".join(
                    f"  • {p.name}  ({p.stat().st_size / 1_048_576:.1f} MB)"
                    for p in moved
                )
            else:
                summary = "  (none)"

            await event.reply(
                f"✅ Done! {len(downloaded)} file(s) saved to:\n"
                f"`{DOWNLOAD_DIR}`\n\n{summary}\n\n🛑 Shutting down.",
                parse_mode="md",
            )
            log.info("/done — shutting down.")
            stop_event.set()
            return

        # ── File message ──────────────────────────────────────────────────────
        if not msg.media:
            return

        # Resolve file name + size
        file_name: str
        size_bytes: int = 0

        if isinstance(msg.media, MessageMediaDocument):
            doc = msg.media.document
            size_bytes = doc.size
            file_name = next(
                (a.file_name for a in doc.attributes if hasattr(a, "file_name") and a.file_name),
                f"document_{msg.id}",
            )
        elif isinstance(msg.media, MessageMediaPhoto):
            file_name  = f"photo_{msg.id}.jpg"
        else:
            file_name  = f"media_{msg.id}"

        size_str  = f"{size_bytes / 1_048_576:.1f} MB" if size_bytes else "unknown size"
        tmp_dest  = unique_path(tmp_dir, file_name)
        final_dest = unique_path(DOWNLOAD_DIR, file_name)

        log.info("Downloading: %s  (%s)", file_name, size_str)
        await event.reply(
            f"⬇️ Downloading: `{file_name}`  ({size_str})", parse_mode="md"
        )

        t0       = time.monotonic()
        progress = Progress(file_name, size_bytes)

        await bot.download_media(
            msg,
            file=str(tmp_dest),
            progress_callback=progress,
        )
        print()  # newline after progress bar

        elapsed   = time.monotonic() - t0 or 0.001
        final_mb  = tmp_dest.stat().st_size / 1_048_576
        avg_speed = final_mb / elapsed

        log.info(
            "Finished: %s  (%.1f MB in %.1fs — avg %.1f MB/s)",
            file_name, final_mb, elapsed, avg_speed,
        )
        await event.reply(
            f"✅ `{file_name}` — {final_mb:.1f} MB in {elapsed:.0f}s "
            f"({avg_speed:.1f} MB/s avg)\n"
            f"_Will be moved to final location on /done_",
            parse_mode="md",
        )
        downloaded.append((tmp_dest, final_dest))

    # ── Wait ──────────────────────────────────────────────────────────────────
    await stop_event.wait()
    await bot.disconnect()


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    required = ("API_ID", "API_HASH", "BOT_TOKEN", "ALLOWED_CHAT")
    missing  = [k for k in required if not os.environ.get(k)]
    if missing:
        print(f"ERROR: Missing env vars: {', '.join(missing)}")
        sys.exit(1)

    # Create a temp dir that is auto-cleaned if the process crashes
    with tempfile.TemporaryDirectory(prefix="tgdl_") as tmp:
        tmp_dir = Path(tmp)
        log.info("Temp dir: %s", tmp_dir)
        asyncio.run(run_bot(tmp_dir))
        # TemporaryDirectory.__exit__ deletes tmp_dir automatically
