from fastapi import FastAPI, UploadFile, File
import requests
import shutil
import os

# Flutter: record -> send audio
# Backend: receive -> send to Sarvam -> return text
# Flutter: display result

app = FastAPI()

SARVAM_API_KEY = "sk_xo0a3ar6_jeoY8UOKQbfe14PGoh9JblFI"
SARVAM_API_URL = "https://api.sarvam.ai/speech-to-text"

@app.get("/")
def home():
    # Connection test endpoint
    return {"message": "Server running"}

@app.post("/upload")
async def upload_audio(file: UploadFile = File(...)):
    print("Request received")
    
    # 1. Save the file locally
    file_location = "audio.m4a"
    with open(file_location, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    print("Sending to Sarvam")
    # 2. Call Sarvam AI Speech-to-Text
    headers = {
        "api-subscription-key": SARVAM_API_KEY, 
        "Authorization": f"Bearer {SARVAM_API_KEY}"
    }
    
    try:
        with open(file_location, "rb") as f:
            files = {
                "file": ("audio.m4a", f, "audio/m4a")
            }
            
            response = requests.post(
                SARVAM_API_URL, 
                headers=headers,
                files=files
            )
            
            print("Response from Sarvam:", response.text)
            response_json = response.json()
            
            # 3. Extract text and return required JSON structure
            text = response_json.get("transcript", response_json.get("text", "Could not parse text"))
            
            return {"text": text}
            
    except Exception as e:
        print("Error processing audio:", str(e))
        return {"text": f"Error: {str(e)}"}
