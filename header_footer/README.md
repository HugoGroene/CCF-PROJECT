
# CCF Disk Image Scenario Generator

## Overview
This script generates ext4 disk images containing common file carving failure scenarios used in digital forensics.  
It creates controlled filesystem and raw-block edge cases to evaluate forensic parsers and file carvers.


---

## Requirements
- Linux
- `sudo` access
- Tools: `dd`, `losetup`, `mkfs.ext4`, `filefrag`, `debugfs`, `xxd`

---

## Files
- `run.sh` – main scenario generation script  
- `test2.pdf` – change the file name in script to use a specific one. 
- `ccf_output/` – output directory containing generated disk images  

---

## Usage

### How to run
```bash
sudo ./run.sh
```