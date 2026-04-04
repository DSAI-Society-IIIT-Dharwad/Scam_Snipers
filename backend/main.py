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

GEMINI_API_KEY = "AIzaSyDSJQwUtgFBPy9DrLZXEhj2wxJpr9t6l4c"

def process_with_gemini(text: str):
    empty_result = {
        "text": None,
        "amount": None,
        "currency": "INR",
        "person": None,
        "intent": None,
        "emotion": None,
        "confidence": 0
    }
    
    if not text or "Could not parse" in text:
        return empty_result
        
    headers = {
        "Content-Type": "application/json"
    }
    
    prompt = f"""
Extract ONLY financial decisions from the speech.

If no financial content:
return null JSON.

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
{text}
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
        url = f"https://generativelanguage.googleapis.com/v1/models/gemini-1.5-pro:generateContent?key={GEMINI_API_KEY}"
        response = requests.post(url, headers=headers, json=payload, timeout=15)
        result = response.json()
        
        print("Gemini FULL RESPONSE:", result)
        
        if "error" in result:
            print("Gemini API Error:", result["error"])
            return empty_result
        
        gemini_text = result["candidates"][0]["content"]["parts"][0]["text"]
        print("Gemini Raw Response:", gemini_text)

        import json
        
        # Clean potential markdown wrapping automatically added by LLMs
        clean_text = gemini_text.strip()
        if clean_text.startswith("```json"):
            clean_text = clean_text[7:]
        if clean_text.startswith("```"):
            clean_text = clean_text[3:]
        if clean_text.endswith("```"):
            clean_text = clean_text[:-3]
            
        structured_data = json.loads(clean_text.strip())
        return structured_data

    except Exception as e:
        print("Gemini parsing error:", str(e))
        return {
            "text": text,
            "amount": None,
            "currency": "INR",
            "person": None,
            "intent": None,
            "emotion": None,
            "confidence": 0
        }

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
            
            # Since the user specifically requested to return the Gemini Output
            # We return it directly, which the Flutter application expects and gracefully handles its missing data fallbacks:
            return gemini_result
            
    except Exception as e:
        print("Error processing audio:", str(e))
        return {
            "text": f"Error: {str(e)}",
            "language": "Error",
            "timestamp": timestamp
        }
