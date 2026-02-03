# Bash Diagnostic Toolkit
Basic and safe diagnostic commands for Linux systems.
Tested on WSL and standard Linux distributions.

## Purpose
This project provides a collection of Bash-based diagnostics to help
identify common system, network, and performance issues on Linux machines.
All commands are read-only and safe to run on personal computers.

## Usage

### 1. Give execution permissions to ths script
``chmod +x diagnostico.sh``

### 2. Run all diagnostic sections
``./diagnostico.sh --all``

### 3. Run a specific section
``./diagnostico.sh --network``

### 4. Use the interactive menu
``./diagnostico.sh --menu``

## Notes
> - This script does not mofify system configuration
> - No administrative privileges are required (some sections may show more information when run as root)