import requests, json

url = "http://localhost:8000/analyze"
tests = [
    "Kal mujhe bank jakar loan lena hai"
    "5 lakh personal loan chahiye",
    "EMI manage ho jayega 2 lakh ka",
    "SIP 5000 monthly karna hai 10% return",
    "12 months tenure 9.5% interest pe",
    "car insurance renew karna hai"
    "ಪ್ರತಿ ತಿಂಗಳು 5000 SIP 12 ಶೇಕಡಾ ಲಾಭ ಭರವಸೆ"
]

print("🧪 TESTING SAKSHI FINANCIAL NLP API\n")
for text in tests:
    resp = requests.post(url, json={"text": text})
    if resp.status_code == 200:
        result = resp.json()
        print(f"'{text}' →")
        print(json.dumps(result, indent=2, ensure_ascii=False))
        print("-" * 50)
    print()
