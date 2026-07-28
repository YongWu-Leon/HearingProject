# test.py
# Diagnostic script: list all audio devices PyAudio detects, to confirm the sound card index.
# Usage: python3 test.py
import pyaudio

p = pyaudio.PyAudio()
for i in range(p.get_device_count()):
    dev = p.get_device_info_by_index(i)
    print(f"Index {i}: {dev['name']}")
p.terminate()
