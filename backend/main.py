from fastapi import FastAPI, UploadFile, File
import requests
import shutil
import os
from pydub import AudioSegment
import webrtcvad

os.environ["PATH"] += os.pathsep + r"C:\ffmpeg\bin"

AudioSegment.converter = r"C:\ffmpeg\bin\ffmpeg.exe"
AudioSegment.ffmpeg = r"C:\ffmpeg\bin\ffmpeg.exe"
AudioSegment.ffprobe = r"C:\ffmpeg\bin\ffprobe.exe"

# Flutter -> audio.m4a  
# Convert -> audio.wav  
# Apply VAD -> clean.wav  
# Send clean.wav to Sarvam  
# Return transcription

app = FastAPI()

SARVAM_API_KEY = "sk_xo0a3ar6_jeoY8UOKQbfe14PGoh9JblFI"
SARVAM_API_URL = "https://api.sarvam.ai/speech-to-text"

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
        # Only process if it is exactly 30 ms long
        if len(frame) == frame_duration_ms:
            # is_speech requires raw audio data, sample rate, and exact frame sizes
            is_speech = vad.is_speech(frame.raw_data, 16000)
            if is_speech:
                clean_audio += frame
                
    clean_audio.export(output_path, format="wav")

@app.get("/")
def home():
    # Connection test endpoint
    return {"message": "Server running"}

@app.post("/upload")
async def upload_audio(file: UploadFile = File(...)):
    print("Request received")
    
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
        # If conversion fails or VAD fails fallback to original audio
    
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
            
            response = requests.post(
                SARVAM_API_URL, 
                headers=headers,
                files=files
            )
            
            print("Response from Sarvam:", response.text)
            response_json = response.json()
            
            # Extract text and return required JSON structure
            text = response_json.get("transcript", response_json.get("text", "Could not parse text"))
            
            return {"text": text}
            
    except Exception as e:
        print("Error processing audio:", str(e))
        return {"text": f"Error: {str(e)}"}
