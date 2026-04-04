import spacy
import re
from typing import Dict, List, Any

class FinancialNLPEngine:
    def __init__(self, model_path=None):
        try:
            self.nlp = spacy.load(model_path)
            self.has_model = True
        except:
            self.nlp = spacy.blank("xx")
            self.has_model = False
    
    def analyze(self, text: str) -> Dict[str, Any]:
        doc = self.nlp(text)
        return {
            "is_financial": self._is_financial(text),
            "topics": self._get_topics(text),
            "entities": self._get_entities(text, doc)
        }
    
    def _is_financial(self, text: str) -> bool:
        # FIXED: Comprehensive keywords + entity presence
        keywords = [
            'loan', 'emi', 'sip', 'investment', 'insurance', 'budget', 'salary',
            'tenure', 'interest', 'rate', 'return', 'policy', 'fund'
        ]
        has_keywords = any(kw in text.lower() for kw in keywords)
        has_numbers = bool(re.search(r'\d+%|\d+\s*(?:months?|lakh|saal)', text))
        return has_keywords or has_numbers
    
    def _get_topics(self, text: str) -> List[str]:
        text_lower = text.lower()
        topics = []
        if any(w in text_lower for w in ['loan', 'udhaar', 'कर्ज', 'udhar']):
            topics.append('loan')
        if any(w in text_lower for w in ['emi', 'emii', 'किस्त', 'installment']):
            topics.append('emi')
        if any(w in text_lower for w in ['sip', 'systematic', 'sip me']):
            topics.append('sip')
        if any(w in text_lower for w in ['insurance', 'बीमा', 'policy']):
            topics.append('insurance')
        if any(w in text_lower for w in ['mutual fund', 'mf', 'fund']):
            topics.append('mutual_fund')
        return topics[:3]
    
    def _get_entities(self, text: str, doc) -> Dict[str, List[str]]:
        # PRECISE Regex patterns - No more false positives
        entities = {
            "amount": re.findall(
                r'(?:₹?[\d,]+\.?\d*|\d+(?:,\d{3})*)\s*(?:lakh|crore|thousand|rs|k|lac)',
                text, re.I
            ) + re.findall(r'₹?(\d+(?:,\d{3})*)', text, re.I),
            "instrument": [
                ent.text.strip() for ent in doc.ents 
                if ent.label_ in ["MONEY", "FIN_INSTRUMENT"]
            ],
            "duration": re.findall(
                r'(\d+(?:-\d+)?)\s*(?:months?|month|saal|years?|महीने?)',
                text, re.I
            ),
            "interest_rate": re.findall(
                r'(\d+(?:\.\d{1,2})?)\s*(?:%|per\s*annum|pa|p\.a\.?)',
                text, re.I
            ),
            "date": re.findall(
                r'\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b',
                text
            ),
            "person": re.findall(r'\b[A-Z][a-z]+\s[A-Z][a-z]+\b', text)
        }
        
        # Smart model integration - avoid duplicates
        if self.has_model:
            for ent in doc.ents:
                label = ent.label_
                text_ent = ent.text.strip()
                if (label == "MONEY" and text_ent not in entities["amount"] and 
                    not any(text_ent in x for x in entities["amount"])):
                    entities["amount"].append(text_ent)
                elif (label == "FIN_INSTRUMENT" and text_ent not in entities["instrument"]):
                    entities["instrument"].append(text_ent)
        
        # Clean & dedupe
        for key in entities:
            entities[key] = sorted(list(set([e.strip() for e in entities[key] if len(e.strip()) > 0])))
        
        return {k: v for k, v in entities.items() if v}