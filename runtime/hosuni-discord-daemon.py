#!/usr/bin/env python3
"""
hosuni Discord DM daemon
- Listens for DMs and #hosuni channel messages
- Whitelist-gated auto-reply
- Local inference first (subtract.sh inference chain), cloud fallback
- Multi-turn conversation state per channel
- YouTube URLs: fetches transcript locally via yt-dlp
- Session log compatible with subtract.sh format
"""

import discord
import subprocess
import re
import os
import json
import datetime
import urllib.request
import urllib.error

TOKEN_PATH = os.path.expanduser("~/.keymaster/jean-discord-token.txt")
WHITELIST_PATH = os.path.expanduser("~/.hosuni-discord-whitelist")
LOG_PATH = os.path.expanduser("~/human/sessions/hosuni-discord.log")
SESSION_LOG_DIR = os.path.expanduser("~/.subtract/log")
SUBTRACT_DIR = os.path.expanduser("~/.subtract")
HOSUNI_CHANNEL_IDS = {1318691951146434622, 1489355263361286204}

HOSUNI_SH = os.path.expanduser("~/subtract.ing/runtime/hosuni.sh")


def log(msg):
    ts = datetime.datetime.now().isoformat()
    with open(LOG_PATH, "a") as f:
        f.write(f"[{ts}] {msg}\n")


def load_whitelist():
    if not os.path.exists(WHITELIST_PATH):
        return set()
    with open(WHITELIST_PATH) as f:
        return set(line.strip() for line in f if line.strip())


def ask_hosuni(prompt, channel_id, context=None):
    req = {"input": prompt, "channel": channel_id}
    if context:
        req["context"] = context
    try:
        result = subprocess.run(
            ["bash", HOSUNI_SH],
            input=json.dumps(req), capture_output=True, text=True, timeout=300,
        )
        if result.stdout.strip():
            resp = json.loads(result.stdout.strip())
            reply = resp.get("response") or resp.get("error")
            source = resp.get("source", "unknown")
            return reply, source
    except Exception as e:
        log(f"  -> hosuni error: {e}")
    return None, "error"


intents = discord.Intents.default()
intents.message_content = True
intents.dm_messages = True
client = discord.Client(intents=intents)


@client.event
async def on_ready():
    log(f"hosuni online as {client.user}")
    print(f"hosuni online as {client.user}")


@client.event
async def on_message(message):
    if message.author == client.user:
        return

    is_dm = isinstance(message.channel, discord.DMChannel)
    is_hosuni_channel = getattr(message.channel, "id", None) in HOSUNI_CHANNEL_IDS

    if not is_dm and not is_hosuni_channel:
        return

    sender_id = str(message.author.id)
    sender_name = message.author.display_name
    content = message.content
    source = "DM" if is_dm else f"#{message.channel.name}"
    channel_id = str(message.channel.id)

    log(f"[{source}] {sender_name} ({sender_id}): {content}")

    whitelist = load_whitelist()
    if sender_id not in whitelist:
        log(f"  -> not in whitelist, ignoring")
        return

    # YouTube transcript pre-fetch
    yt_match = re.search(
        r"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/shorts/)([A-Za-z0-9_-]{11})",
        content,
    )
    transcript_json = None
    if yt_match:
        video_id = yt_match.group(1)
        video_url = f"https://www.youtube.com/watch?v={video_id}"
        log(f"  -> fetching transcript for {video_id}")
        try:
            title_result = subprocess.run(
                ["/usr/local/bin/yt-dlp", "--print", "title", video_url],
                capture_output=True, text=True, timeout=30,
            )
            title = title_result.stdout.strip() or video_id
            subprocess.run(
                [os.path.expanduser("~/scripts/yt-transcript.sh"), video_url],
                capture_output=True, text=True, timeout=60,
            )
            transcript_path = os.path.expanduser(
                f"~/human/transcripts/{video_id}.txt"
            )
            if os.path.exists(transcript_path):
                with open(transcript_path) as f:
                    transcript_text = f.read().strip()
                transcript_json = json.dumps({
                    "video_id": video_id,
                    "url": video_url,
                    "title": title,
                    "transcript": transcript_text,
                })
                log(f"  -> transcript fetched ({len(transcript_text)} chars)")
            else:
                log(f"  -> transcript file not created")
        except Exception as e:
            log(f"  -> transcript fetch error: {e}")

    # Build user prompt
    prompt = content
    context = None
    if transcript_json:
        prompt = re.sub(r"https?://\S+", "", content).strip() or "Analyze this video transcript."
        context = transcript_json

    reply, inference_source = ask_hosuni(prompt, channel_id, context)

    if not reply:
        log(f"  -> no response from hosuni")
        return

    log(f"  -> [{inference_source}] reply: {reply[:200]}")

    try:
        for i in range(0, len(reply), 2000):
            await message.channel.send(reply[i : i + 2000])
        log(f"  -> sent ({len(reply)} chars)")
    except Exception as e:
        log(f"  -> send error: {e}")


token = open(TOKEN_PATH).read().strip()
client.run(token)
