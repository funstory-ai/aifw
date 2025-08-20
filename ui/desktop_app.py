"""OneAIFW Desktop UI (Tkinter) - local API client (no HTTP)."""
import tkinter as tk
from tkinter import ttk, messagebox
import json
import sys, os

# Ensure project root is on sys.path for package imports when running from `ui/`
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

# Use local in-process API to avoid HTTP dependency
from services.app import local_api

def do_anonymize():
    txt = txt_in.get("1.0", tk.END).strip()
    if not txt:
        return
    try:
        res = local_api.anonymize(text=txt)
        txt_out.delete("1.0", tk.END)
        txt_out.insert(tk.END, json.dumps(res, ensure_ascii=False, indent=2))
    except Exception as e:
        messagebox.showerror("Error", str(e))

def do_restore():
    try:
        data = json.loads(txt_out.get("1.0", tk.END))
        restored_text = local_api.restore(
            text=data.get("text", ""),
            placeholders_map=data.get("placeholdersMap", {}),
        )
        res = {"text": restored_text}
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
