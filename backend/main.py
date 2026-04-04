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
        password="YOUR_PASSWORD",
        host="localhost",
        port="5432"
    )
    cur = conn.cursor()
    
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
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """)
    conn.commit()
except Exception as e:
    print("Database connection error:", e)
    conn = None
    cur = None

def generate_summary(data):
    if not data or data.get("text") is None:
        return None

    amount = data.get("amount")
    person = data.get("person")
    intent = data.get("intent")
    emotion = data.get("emotion")

    parts = []

    if intent == "transfer":
        parts.append(f"Transfer ₹{amount} to {person}")
    elif intent == "investment":
        parts.append(f"Investment of ₹{amount}")
    elif intent == "loan":
        parts.append(f"Loan discussion of ₹{amount}")
    else:
        parts.append("Financial activity detected")

    if emotion == "stress":
        parts.append("user is stressed")
    elif emotion == "positive":
        parts.append("user feels confident")
    else:
        parts.append("neutral sentiment")

    return ", ".join(parts)

def store_data(data, summary):
    if cur is None:
        return
    cur.execute("""
        INSERT INTO financial_insights 
        (text, amount, currency, person, intent, emotion, confidence, summary)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """, (
        data.get("text"),
        data.get("amount"),
        data.get("currency"),
        data.get("person"),
        data.get("intent"),
        data.get("emotion"),
        data.get("confidence"),
        summary
    ))
    conn.commit()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

if not GEMINI_API_KEY:
    raise ValueError("GEMINI_API_KEY not found. Please set it in environment variables.")

conversation_buffer = []

def build_context(new_text):
    global conversation_buffer

    if new_text:
        conversation_buffer.append(new_text)

    # Keep only last 3 chunks
    if len(conversation_buffer) > 3:
        conversation_buffer.pop(0)

    # Combine into context
    context = " ".join(conversation_buffer)
    return context

def clean_gemini_response(text):
    if not text:
        return None

    text = text.strip()

    # Remove markdown wrappers
    text = re.sub(r"```json", "", text)
    text = re.sub(r"```", "", text)
    text = text.strip()

    # Handle null safely
    if text.lower() == "null":
        return None

    try:
        return json.loads(text)
    except Exception as e:
        print("JSON parsing error:", e)
        return None

def process_with_gemini(text: str):
    empty_result = {
        "data": None,
        "summary": None,
        "message": "No financial insight detected"
    }
    
    if not text or "Could not parse" in text:
        return empty_result
        
    headers = {
        "Content-Type": "application/json"
    }
    
    context_text = build_context(text)
    
    prompt = f"""
Extract ONLY financial decisions from the speech.

Extract financial information if present. If weak financial context exists, still extract best possible interpretation.

Otherwise:
- Convert to English
- Extract amount (number only)
- Extract person name
- Classify intent (transfer, loan, investment, expense)
- Detect emotion (stress, neutral, positive)
- Do NOT hallucinate

Return JSON ONLY:

{{
  "text": "...",
  "amount": number or null,
  "currency": "INR",
  "person": "... or null",
  "intent": "...",
  "emotion": "...",
  "confidence": 0-1
}}

Speech:
{context_text}
"""
    
    payload = {
        "contents": [
            {
                "parts": [
                    {"text": prompt}
                ]
            }
        ]
    }
    
    try:
        url = f"https://generativelanguage.googleapis.com/v1/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}"
        response = requests.post(url, headers=headers, json=payload, timeout=15)
        result = response.json()
        
        print("Gemini FULL RESPONSE:", result)
        
        if "error" in result:
            print("Gemini API Error:", result["error"])
            return empty_result
        
        gemini_text = result["candidates"][0]["content"]["parts"][0]["text"]
        print("Gemini Raw Response:", gemini_text)

        clean_output = clean_gemini_response(gemini_text)
        
        if clean_output is None:
            return empty_result
            
        return clean_output

    except Exception as e:
        print("Gemini parsing error:", str(e))
        return empty_result

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
    headers = {
        "api-subscription-key": SARVAM_API_KEY, 
        "Authorization": f"Bearer {SARVAM_API_KEY}"
    }
    
    try:
        with open(final_file, "rb") as f:
            files = {
                "file": (filename, f, mime_type)
            }
            
            # Send language_code parameter as instructed
            response = requests.post(
                SARVAM_API_URL, 
                headers=headers,
                files=files,
                data={"language_code": "unknown"}
            )
            
            response_json = response.json()
            
            if "error" in response_json:
                print("Sarvam Error:", response_json["error"]["message"])
                return {"text": "Error from STT"}
            
            # Extract text and raw language
            text = response_json.get("transcript", "Could not parse text")
            raw_lang = response_json.get("language_code", "Unknown")
            
            gemini_result = process_with_gemini(text)
            
            print("Sarvam Response:", response_json)
            print("Raw STT:", text)
            print("Gemini Output:", gemini_result)
            
            summary = generate_summary(gemini_result)
            store_data(gemini_result, summary)
            
            return {
                "data": gemini_result,
                "summary": summary
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
