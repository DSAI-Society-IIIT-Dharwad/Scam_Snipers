import os
from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, UploadFile, File, Form
import requests
import shutil
import os
import re
from pydub import AudioSegment
import webrtcvad

os.environ["PATH"] += os.pathsep + r"C:\ffmpeg\bin"

AudioSegment.converter = r"C:\ffmpeg\bin\ffmpeg.exe"
AudioSegment.ffmpeg = r"C:\ffmpeg\bin\ffmpeg.exe"
AudioSegment.ffprobe = r"C:\ffmpeg\bin\ffprobe.exe"

app = FastAPI()

SARVAM_API_KEY = "sk_xo0a3ar6_jeoY8UOKQbfe14PGoh9JblFI"
SARVAM_API_URL = "https://api.sarvam.ai/speech-to-text"

LANGUAGE_MAP = {
    "en-IN": "English",
    "hi-IN": "Hindi",
    "kn-IN": "Kannada",
    "ta-IN": "Tamil",
    "bn-IN": "Bengali",
}

import json
import psycopg2

try:
    conn = psycopg2.connect(
        dbname="finance_db",
        user="postgres",
        password="postgres123",
        host="localhost",
        port="5433"
    )
    cur = conn.cursor()
    print("✅ PostgreSQL Connected")
    
    cur.execute("""
    CREATE TABLE IF NOT EXISTS financial_insights (
        id SERIAL PRIMARY KEY,
        text TEXT,
        amount FLOAT,
        currency TEXT,
        person TEXT,
        intent TEXT,
        emotion TEXT,
        confidence FLOAT,
        summary TEXT,
        raw_json TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """)
    # Add raw_json column to existing tables that may not have it
    try:
        cur.execute("ALTER TABLE financial_insights ADD COLUMN IF NOT EXISTS raw_json TEXT;")
    except Exception:
        pass
    conn.commit()
except Exception as e:
    print("❌ Database connection error:", e)
    conn = None
    cur = None

def generate_summary(extraction):
    """Build a human-readable summary from the new flat events schema."""
    if not extraction:
        return None

    # Use the pre-built summary from insights if available
    insights = extraction.get("insights", {})
    summary = insights.get("summary", "")
    if summary:
        return summary

    # Fallback: build from events
    events = extraction.get("events", [])
    parts = []
    for ev in events:
        conf = ev.get("confidence", "")
        product = ev.get("product", "")
        intent = ev.get("intent", "")
        amt = ev.get("amount") or {}
        target = amt.get("target") or amt.get("current")
        t = ev.get("time", "")
        line = f"[{conf}] {intent} {product}"
        if target:
            line += f" ₹{target}"
        if t:
            line += f" ({t})"
        parts.append(line)

    emotion = extraction.get("emotion", "")
    if emotion:
        parts.append(f"Emotion: {emotion}")

    risk_flags = insights.get("risk_flags", [])
    if risk_flags:
        parts.append("Risks: " + ", ".join(risk_flags))

    return " | ".join(parts) if parts else None

def _extract_flat_fields(extraction):
    """Extract flat DB-compatible fields from the new flat events schema."""
    if not extraction:
        return {}

    events = extraction.get("events", [])
    first = events[0] if events else {}
    amt = first.get("amount") or {}

    amount = amt.get("target") or amt.get("current")
    conf_str = first.get("confidence", "MENTIONED")
    confidence = {"DECIDED": 1.0, "CONSIDERING": 0.7, "MENTIONED": 0.5}.get(conf_str, 0.5)

    risk = first.get("risk")
    risk_str = risk.get("type") if risk else None

    insights = extraction.get("insights", {})
    text = insights.get("summary") or (first.get("raw_text") if first else None)

    return {
        "text": text,
        "amount": amount,
        "currency": "INR",
        "person": None,
        "intent": first.get("intent"),
        "emotion": extraction.get("emotion"),
        "confidence": confidence,
    }

def store_data(extraction, summary):
    if cur is None:
        print("⚠️ DB not connected, skipping insert")
        return
    if not extraction:
        return

    flat = _extract_flat_fields(extraction)

    try:
        cur.execute("""
            INSERT INTO financial_insights
            (text, amount, currency, person, intent, emotion, confidence, summary, raw_json)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            flat.get("text"),
            flat.get("amount"),
            flat.get("currency"),
            flat.get("person"),
            flat.get("intent"),
            flat.get("emotion"),
            flat.get("confidence"),
            summary,
            json.dumps(extraction)
        ))
        conn.commit()
        print("✅ Data stored in PostgreSQL")
    except Exception as e:
        print("❌ Insert error:", e)

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

if not GEMINI_API_KEY:
    raise ValueError("GEMINI_API_KEY not found. Please set it in environment variables.")

GEMINI_EXTRACTION_SYSTEM_PROMPT = """
You are a STRICT financial event extractor and insight generator for Indian users.

Input may be multilingual (English, Hindi, Hinglish, Tamil, Telugu, etc.).
Your job is to extract CLEAN, DATABASE-READY financial events and generate minimal, accurate insights.

⚠️ OUTPUT RULES (MANDATORY)
* Return ONLY valid JSON
* No markdown, no explanation, no extra text
* Follow schema EXACTLY
* Do NOT add extra fields
* Do NOT change field names

──────────────── ENTITY TYPES ────────────────

FIN_PRODUCT:
Allowed values ONLY:
SIP | FD | loan | EMI | insurance | mutual_fund |
PPF | NPS | ELSS | credit_card | crypto | property | other

FIN_INTENT:
START | STOP | INCREASE | DECREASE | PAY | DEFER | QUESTION

CONFIDENCE:
DECIDED     → clear action taken
CONSIDERING → thinking or asking
MENTIONED   → just discussion

FIN_AMOUNT:
* value must ALWAYS be a number (no ₹ symbol, no strings)
* currency ALWAYS "INR"
* unit: absolute | percent | vague
If 2 amounts exist:
  assign lower  → current
  assign higher → target
  compute delta  = target - current
If no amount clearly mentioned → set all amount fields to null

FIN_TIME:
Normalize to short English only:
"\u0906\u091c"          → "today"
"kal"          → "tomorrow"
"agle mahine"  → "next month"
"3 saal"       → "3 years"
If unclear → null

FIN_RISK:
Allowed values ONLY:
OVER_LEVERAGE | DEBT_STRESS | FOMO | IMPULSE | UNVERIFIED_TIP
Severity: HIGH | MEDIUM | LOW
If no clear risk → set risk = null

──────────────── EVENT RULES ────────────────

Each event MUST include: product, intent, confidence
Optional: amount, time, risk
Each event represents ONE financial action or discussion.

──────────────── STRICT SAFETY RULES ────────────────

1. NO HALLUCINATION: If not explicitly present → return null. DO NOT assume, infer, or guess.
2. STRICT ENUM: Only use allowed values for product, intent, risk.
3. STRICT NUMERIC: Amounts must be numbers only. No ₹ or symbols. No strings.
4. STRICT NULL: If any field is missing → use null. No empty strings.
5. STRICT INSIGHT: Insights only from DECIDED events. No actions for CONSIDERING/MENTIONED.

──────────────── OUTPUT FORMAT (STRICT) ────────────────

{
  "events": [
    {
      "event_id": "E1",
      "product": "SIP",
      "intent": "INCREASE",
      "confidence": "DECIDED",
      "amount": {
        "current": 5000,
        "target": 8000,
        "delta": 3000,
        "unit": "absolute"
      },
      "time": "next month",
      "risk": {
        "type": "FOMO",
        "severity": "MEDIUM"
      },
      "raw_text": "SIP badha dete hain 5000 se 8000 next month"
    }
  ],
  "insights": {
    "decisions": [],
    "action_items": [],
    "risk_flags": [],
    "summary": ""
  },
  "emotion": "neutral",
  "language_detected": "hinglish"
}

If there is NO financial content at all, return exactly: null
"""

def clean_llm_response(raw):
    """Strip markdown fences and parse JSON. Returns None if null/invalid."""
    if not raw:
        return None
    clean = raw.strip()
    clean = re.sub(r"```json", "", clean)
    clean = re.sub(r"```", "", clean)
    clean = clean.strip()
    if clean.lower() == "null":
        return None
    try:
        return json.loads(clean)
    except Exception as e:
        print("JSON parsing error:", e)
        return None

def process_with_gemini(text: str):
    global last_gemini_text

    if not text or text.strip() == "":
        return None

    financial_keywords = [
        # English
        "money", "rupees", "₹", "loan", "emi", "pay", "transfer", "send",
        "investment", "mutual fund", "expense", "salary", "debt", "bill",
        "budget", "saving", "bank", "interest", "finance", "cost",
        "afford", "expensive", "price", "fee", "tax", "income", "sip",
        "spend", "spent", "lend", "borrow", "credit", "debit", "due",
        # Hindi / Indic
        "ईएएमआई", "ईएमआई", "पैसा", "पैसे", "रुपए", "लोन",
        "खर्च", "निवेश", "बचत", "कर्ज", "उधार", "बिल",
        "बैंक", "वेतन", "टैक्स"
    ]

    if not any(word in text.lower() for word in financial_keywords):
        return None

    headers = {"Content-Type": "application/json"}

    payload = {
        "system_instruction": {
            "parts": [{"text": GEMINI_EXTRACTION_SYSTEM_PROMPT}]
        },
        "contents": [
            {
                "role": "user",
                "parts": [{"text": f"Transcript:\n{text}"}]
            }
        ]
    }

    try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}"
        response = requests.post(url, headers=headers, json=payload, timeout=20)

        if response.status_code == 429:
            print("⚠️ Gemini 429 Quota Exceeded! Waiting 25s...")
            time.sleep(25)
            response = requests.post(url, headers=headers, json=payload, timeout=20)
            if response.status_code == 429:
                print("❌ Gemini 429 again! Skipping.")
                return None

        result = response.json()
        print("Gemini FULL RESPONSE:", result)

        if "error" in result:
            print("Gemini API Error:", result["error"])
            return None

        raw_text = result["candidates"][0]["content"]["parts"][0]["text"]
        print("Gemini Raw Response:", raw_text)

        extraction = clean_llm_response(raw_text)

        if extraction is None:
            return None

        # Duplicate check on insights summary
        insights = extraction.get("insights", {})
        first_summary = insights.get("summary") or (extraction.get("events", [{}])[0].get("raw_text"))

        if first_summary and first_summary == last_gemini_text:
            print("Duplicate detected, skipping")
            return None

        last_gemini_text = first_summary
        print("FINAL EXTRACTION:", extraction)
        return extraction

    except Exception as e:
        print("Gemini parsing error:", str(e))
        return None


def detect_language_label(text: str, base_lang_code: str) -> str:
    # Rule: If english characters exist alongside local indic fonts, label code-mixed
    has_english = bool(re.search(r'[a-zA-Z]', text))
    has_indic = bool(re.search(r'[\u0900-\u097F\u0980-\u09FF\u0B80-\u0BFF\u0C80-\u0CFF]', text))
    
    if has_english and has_indic:
        return "code-mixed"
        
    return LANGUAGE_MAP.get(base_lang_code, base_lang_code)

def convert_to_wav(input_file, output_file):
    audio = AudioSegment.from_file(input_file)
    audio = audio.set_channels(1).set_frame_rate(16000)
    audio.export(output_file, format="wav")

def apply_vad(input_path: str, output_path: str):
    vad = webrtcvad.Vad(2)
    audio = AudioSegment.from_file(input_path, format="wav")
    
    # Process audio in 30 ms frames
    frame_duration_ms = 30
    clean_audio = AudioSegment.empty()
    
    for i in range(0, len(audio), frame_duration_ms):
        frame = audio[i:i + frame_duration_ms]
        if len(frame) == frame_duration_ms:
            is_speech = vad.is_speech(frame.raw_data, 16000)
            if is_speech:
                clean_audio += frame
                
    clean_audio.export(output_path, format="wav")

import threading
import time

text_buffer = []
buffer_lock = threading.Lock()
buffer_timer = None
is_processing = False
last_gemini_text = None

def trigger_buffer_flush():
    global text_buffer, buffer_timer, is_processing

    if is_processing:
        print("⏳ Timer fired but request is processing, skipping.")
        return

    with buffer_lock:
        if not text_buffer:
            return
        combined_text = " ".join(text_buffer)
        text_buffer.clear()
    
    print("⏳ Time-based fallback triggered (10s no chunks)")
    print("Raw STT Batch (Timer):", combined_text)
    
    gemini_result = process_with_gemini(combined_text)
    print("Gemini Output (Timer):", gemini_result)
    
    if gemini_result:
        summary = generate_summary(gemini_result)
        print("Generated Summary (Timer):", summary)
        store_data(gemini_result, summary)

def reset_buffer_timer():
    global buffer_timer
    if buffer_timer:
        buffer_timer.cancel()
    buffer_timer = threading.Timer(10.0, trigger_buffer_flush)
    buffer_timer.daemon = True
    buffer_timer.start()

@app.get("/")
def home():
    # Connection test endpoint
    return {"message": "Server running"}

@app.post("/upload")
async def upload_audio(file: UploadFile = File(...), timestamp: str = Form("Unknown")):
    print(f"Request received for chunk at {timestamp}")
    
    # 1. Save the file locally
    file_location = "audio.m4a"
    wav_path = "audio.wav"
    clean_path = "clean.wav"
    
    with open(file_location, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
    print("Original file saved")
        
    final_file = file_location
    mime_type = "audio/x-m4a"
    filename = "audio.m4a"
    
    # 2. Audio Preprocessing
    try:
        print("Checking input file:", os.path.exists(file_location))
        print("Converting to WAV...")
        convert_to_wav(file_location, wav_path)
        
        if os.path.exists(wav_path):
            print("WAV file created successfully")
            apply_vad(wav_path, clean_path)
            
            if os.path.exists(clean_path):
                print("VAD applied")
                final_file = clean_path
                mime_type = "audio/wav"
                filename = "clean.wav"
            else:
                print("VAD failed to output clean file")
        else:
            print("WAV creation FAILED")
            
    except Exception as e:
        print("Preprocessing error, falling back to original m4a audio:", e)
    
    print("Sending clean audio to Sarvam")
    # 3. Call Sarvam AI Speech-to-Text
    global is_processing
    is_processing = True
    headers = {
        "api-subscription-key": SARVAM_API_KEY, 
        "Authorization": f"Bearer {SARVAM_API_KEY}"
    }
    
    try:
        with open(final_file, "rb") as f:
            files = {
                "file": (filename, f, mime_type)
            }
            
            response = requests.post(
                SARVAM_API_URL, 
                headers=headers,
                files=files,
                data={"language_code": "unknown"}
            )
            
            print("Sarvam Status:", response.status_code)
            print("Sarvam Response:", response.text)
            
            is_processing = False
            response_json = response.json()
            
            if "error" in response_json:
                print("Sarvam Error:", response_json["error"]["message"])
                return {"text": "Error from STT"}
            
            # Extract text and raw language
            text = response_json.get("transcript", "Could not parse text")
            raw_lang = response_json.get("language_code", "Unknown")
            
            should_flush = False
            combined_text = ""
            
            if text and text.strip() and "Could not parse" not in text:
                with buffer_lock:
                    text_buffer.append(text)
                    if len(text_buffer) >= 5:
                        should_flush = True
                        combined_text = " ".join(text_buffer)
                        text_buffer.clear()
                        if buffer_timer:
                            buffer_timer.cancel()
                    else:
                        reset_buffer_timer()

            if should_flush:
                gemini_result = process_with_gemini(combined_text)
                
                print("Raw STT Batch:", combined_text)
                print("Gemini Output:", gemini_result)
                
                if gemini_result is None:
                    return {
                        "data": None,
                        "summary": None,
                        "message": "No financial insight detected"
                    }
                
                summary = generate_summary(gemini_result)
                print("Generated Summary:", summary)
                store_data(gemini_result, summary)
                
                return {
                    "data": gemini_result,
                    "summary": summary,
                    "message": "success"
                }
            else:
                return {
                    "data": None,
                    "summary": None,
                    "message": "Buffered chunk"
                }
            
    except Exception as e:
        print("Error processing audio:", str(e))
        return {
            "text": f"Error: {str(e)}",
            "language": "Error",
            "timestamp": timestamp
        }

@app.get("/summary")
def get_final_summary():
    if cur is None:
        return {"final_summary": "Database unavailable"}
    cur.execute("SELECT summary FROM financial_insights")
    rows = cur.fetchall()
    summaries = [row[0] for row in rows if row[0]]
    return {"final_summary": " | ".join(summaries)}

@app.get("/insights")
def get_insights():
    if cur is None:
        return {"insights": []}
    
    try:
        cur.execute("""
            SELECT id, text, amount, person, intent, emotion, summary, created_at
            FROM financial_insights
            ORDER BY created_at DESC
            LIMIT 20
        """)
        
        rows = cur.fetchall()

        results = []
        for row in rows:
            results.append({
                "id": row[0],
                "text": row[1],
                "amount": row[2],
                "person": row[3],
                "intent": row[4],
                "emotion": row[5],
                "summary": row[6],
                "created_at": str(row[7])
            })

        return {"insights": results}
    except Exception as e:
        print("Error fetching insights:", e)
        return {"insights": []}
