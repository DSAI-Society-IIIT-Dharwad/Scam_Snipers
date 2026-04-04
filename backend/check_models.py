import requests

API_KEY = "AIzaSyDISflHUJPdGw_bGkotUN9ibej73LIOEgI"

url = f"https://generativelanguage.googleapis.com/v1/models?key={API_KEY}"

response = requests.get(url)

print("Status Code:", response.status_code)
print("Response:")

try:
    data = response.json()
    print(data)
    
    if "models" in data:
        print("\nAvailable Models:\n")
        for model in data["models"]:
            print(model["name"])
    else:
        print("\nNo models found or API not enabled.")

except Exception as e:
    print("Error parsing response:", str(e))
