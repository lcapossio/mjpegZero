#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Minimal tkinter image display test: show one JPEG in a window.
# Usage: python show_jpg.py <file.jpg>
import sys
import tkinter as tk
from PIL import Image, ImageTk

path = sys.argv[1] if len(sys.argv) > 1 else "out.jpg"
root = tk.Tk()
root.title("STATIC TEST - " + path)
root.geometry("1000x650+100+100")
img = Image.open(path).convert("RGB")
img.thumbnail((1000, 600))
photo = ImageTk.PhotoImage(img)
tk.Label(root, image=photo).pack()
tk.Label(root, text="if you see colorbars+box above, tkinter/ImageTk works",
         font=("Consolas", 12)).pack()
root.lift()
root.attributes("-topmost", True)
root.mainloop()
