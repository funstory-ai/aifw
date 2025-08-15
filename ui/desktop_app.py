"""OneAIFW Desktop UI (Tkinter) - simple client for the Presidio service"""
import tkinter as tk
from tkinter import ttk, messagebox
import requests, json

SERVICE_URL = "http://127.0.0.1:8000"
API_KEY = None  # set if your service uses an API key

def post(path, payload):
    headers = {"Content-Type":"application/json"}
    if API_KEY:
        headers["X-API-Key"] = API_KEY
    r = requests.post(SERVICE_URL + path, json=payload, headers=headers)
    r.raise_for_status()
    return r.json()

def do_anonymize():
    txt = txt_in.get("1.0", tk.END).strip()
    if not txt:
        return
    try:
        res = post("/api/anonymize", {"text": txt})
        txt_out.delete("1.0", tk.END)
        txt_out.insert(tk.END, json.dumps(res, ensure_ascii=False, indent=2))
    except Exception as e:
        messagebox.showerror("Error", str(e))

def do_restore():
    try:
        data = json.loads(txt_out.get("1.0", tk.END))
        res = post("/api/restore", {"text": data.get("text", ""), "placeholdersMap": data.get("placeholdersMap", {})})
        txt_out.delete("1.0", tk.END)
        txt_out.insert(tk.END, json.dumps(res, ensure_ascii=False, indent=2))
    except Exception as e:
        messagebox.showerror("Error", str(e))

root = tk.Tk()
root.title("OneAIFW - Presidio Client")
root.geometry("900x650")
frame = ttk.Frame(root, padding=12)
frame.pack(fill=tk.BOTH, expand=True)

lbl = ttk.Label(frame, text="Input text:")
lbl.pack(anchor="w")
txt_in = tk.Text(frame, height=10)
txt_in.pack(fill=tk.BOTH, expand=True)

btn_frame = ttk.Frame(frame)
btn_frame.pack(fill=tk.X, pady=6)
ttk.Button(btn_frame, text="Anonymize →", command=do_anonymize).pack(side=tk.LEFT, padx=6)
ttk.Button(btn_frame, text="← Restore", command=do_restore).pack(side=tk.LEFT, padx=6)

lbl2 = ttk.Label(frame, text="Output (text + placeholdersMap):")
lbl2.pack(anchor="w")
txt_out = tk.Text(frame, height=18)
txt_out.pack(fill=tk.BOTH, expand=True)

root.mainloop()
