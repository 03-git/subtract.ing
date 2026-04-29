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

conversations = {}
MAX_TURNS = 20


def log(msg):
    ts = datetime.datetime.now().isoformat()
    with open(LOG_PATH, "a") as f:
        f.write(f"[{ts}] {msg}\n")


def session_log(channel_id, role, content):
    os.makedirs(SESSION_LOG_DIR, exist_ok=True)
    path = os.path.join(SESSION_LOG_DIR, f"hosuni-{channel_id}.log")
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    tag = "Q" if role == "user" else "A"
    line = content.replace("\t", "\\t").replace("\n", " ")[:500]
    with open(path, "a") as f:
        f.write(f"{ts}\t{tag}\t{line}\n")


def load_whitelist():
    if not os.path.exists(WHITELIST_PATH):
        return set()
    with open(WHITELIST_PATH) as f:
        return set(line.strip() for line in f if line.strip())


def get_inference_endpoint():
    host = "localhost"
    port = "8085"
    host_file = os.path.join(SUBTRACT_DIR, "inference_host")
    port_file = os.path.join(SUBTRACT_DIR, "inference_port")
    if os.path.exists(host_file):
        with open(host_file) as f:
            h = f.read().strip()
            if h:
                host = h
    if os.path.exists(port_file):
        with open(port_file) as f:
            p = f.read().strip()
            if p:
                port = p
    return f"http://{host}:{port}/v1/chat/completions"


def get_messages(channel_id):
    if channel_id not in conversations:
        conversations[channel_id] = []
    return conversations[channel_id]


def add_message(channel_id, role, content):
    msgs = get_messages(channel_id)
    msgs.append({"role": role, "content": content})
    if len(msgs) > MAX_TURNS * 2:
        conversations[channel_id] = msgs[-(MAX_TURNS * 2):]


def ask_local(messages):
    endpoint = get_inference_endpoint()
    payload = json.dumps({
        "messages": messages,
        "max_tokens": 2048,
        "temperature": 0.7,
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(
        endpoint, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        choices = body.get("choices", [])
        if choices:
            return choices[0]["message"]["content"].strip()
    except (urllib.error.URLError, Exception) as e:
        log(f"  -> local inference error: {e}")
    return None


def ask_cloud(prompt):
    try:
        result = subprocess.run(
            [os.path.expanduser("~/.local/bin/claude"), "-p", "-c",
             "--allowedTools", "WebSearch"],
            input=prompt, capture_output=True, text=True, timeout=300,
        )
        return result.stdout.strip() or None
    except Exception as e:
        log(f"  -> claude -p error: {e}")
        return None


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
    if transcript_json:
        user_text = re.sub(r"https?://\S+", "", content).strip()
        if user_text:
            prompt = f"{user_text}\n\nThe transcript has already been fetched. Do not attempt to access the URL. Analyze the following transcript data:\n\n{transcript_json}"
        else:
            prompt = f"Analyze the following YouTube video transcript. Do not attempt to access the URL -- the full transcript is provided below.\n\n{transcript_json}"
    else:
        prompt = content

    add_message(channel_id, "user", prompt)
    session_log(channel_id, "user", prompt)

    # Local first, cloud fallback
    messages = get_messages(channel_id)
    reply = ask_local(messages)
    inference_source = "local"

    if not reply:
        log(f"  -> local empty, falling back to cloud")
        reply = ask_cloud(prompt)
        inference_source = "cloud"

    if not reply:
        log(f"  -> no model available")
        return

    add_message(channel_id, "assistant", reply)
    session_log(channel_id, "assistant", reply)
    log(f"  -> [{inference_source}] reply: {reply[:200]}")

    try:
        for i in range(0, len(reply), 2000):
            await message.channel.send(reply[i : i + 2000])
        log(f"  -> sent ({len(reply)} chars)")
    except Exception as e:
        log(f"  -> send error: {e}")


token = open(TOKEN_PATH).read().strip()
client.run(token)
