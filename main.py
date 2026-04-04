from fastapi import FastAPI
from pydantic import BaseModel
from financial_nlp_engine import FinancialNLPEngine
import uvicorn

app = FastAPI(title="🛡️ Sakshi Financial NLP API - NER Trained")

# YOUR EXACT MODEL PATH
engine = FinancialNLPEngine(r"E:\financial-api1.1\financial_entity_model\content\financial_model")

class AnalyzeRequest(BaseModel):
    text: str

@app.post("/analyze")
async def analyze(request: AnalyzeRequest):
    return engine.analyze(request.text)

@app.get("/")
async def home():
    return {
        "message": "Sakshi NER Financial API ✅", 
        "model": "financial_entity_model loaded",
        "endpoint": "/analyze"
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)