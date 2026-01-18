# System Architecture

## Overview
The AI Assistant follows a modular and lightweight architecture
that separates the frontend interface from backend services.

## Architecture Components

### 1. Frontend
- Web-based chat interface
- HTML, CSS, and JavaScript
- Communicates with backend proxies via HTTP

### 2. Backend Proxies
- PHP-based proxy for Ollama API
- PHP-based proxy for LibreY search engine
- Handles request forwarding and response parsing

### 3. LLM Engine
- Ollama running locally
- Qwen language model
- No external API dependency

### 4. Meta Search Engine
- LibreY deployed separately
- Used for privacy-friendly search aggregation

## Design Principles
- Local-first AI processing
- Minimal external dependencies
- Simple and readable architecture
- Automation-friendly deployment
