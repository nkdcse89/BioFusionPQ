FROM python:3.11-slim

# (optional) speed up builds for numpy / pynacl
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

# App code
COPY src ./src
COPY scripts ./scripts

ENV PYTHONUNBUFFERED=1

# Default command: API on :9000 (overridden by compose for UI)
CMD ["python", "-m", "uvicorn", "src.protochain:app", "--host", "0.0.0.0", "--port", "9000"]
