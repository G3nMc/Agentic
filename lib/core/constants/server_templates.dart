const String defaultPythonServerTemplate = r"""
from flask import Flask, request, jsonify
from transformers import pipeline
import sys

app = Flask(__name__)

# Initialize the model pipeline
try:
    pipe = pipeline(
        "text-generation",
        model="{{MODEL_ID}}",
        device=0 if sys.platform != 'darwin' else -1  # Use GPU if available
    )
except Exception as e:
    print(f"Error loading model: {e}")
    pipe = None

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": "{{MODEL_ID}}"})

@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    if pipe is None:
        return jsonify({"error": "Model not loaded"}), 500

    try:
        data = request.json
        messages = data.get("messages", [])
        max_tokens = data.get("max_tokens", 2048)
        temperature = data.get("temperature", 0.7)

        # Convert messages to prompt format
        prompt = "\n".join([
            f"{msg['role'].upper()}: {msg['content']}"
            for msg in messages
        ])

        # Generate response
        response = pipe(
            prompt,
            max_new_tokens=max_tokens,
            temperature=temperature,
            do_sample=True,
        )

        content = response[0]["generated_text"]

        return jsonify({
            "choices": [{
                "message": {"content": content},
                "finish_reason": "stop"
            }]
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/v1/models", methods=["GET"])
def list_models():
    return jsonify({
        "data": [{"id": "{{MODEL_ID}}", "object": "model"}]
    })

if __name__ == "__main__":
    print("Starting server on http://{{HOST}}:{{PORT}}")
    print(f"Model: {{MODEL_ID}}")
    app.run(host="{{HOST}}", port={{PORT}}, debug=False)
""";

const String ollamaServerTemplate = r"""
# Ollama Configuration
# 1. Install Ollama from https://ollama.ai
# 2. Run: ollama pull {{MODEL_ID}}
# 3. Run: ollama serve

# The server will be available at http://{{HOST}}:{{PORT}}
# Ollama uses OpenAI-compatible API by default on port 11434
""";

const String llamaCppTemplate = r"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from llama_cpp import Llama
import json
import threading

class RequestHandler(BaseHTTPRequestHandler):
    llm = None

    def do_post(self):
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers['Content-Length'])
            body = self.rfile.read(content_length)
            data = json.loads(body)

            messages = data.get("messages", [])
            prompt = "\n".join([f"{m['role']}: {m['content']}" for m in messages])

            response = self.llm(prompt, max_tokens=data.get("max_tokens", 2048))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                "choices": [{"message": {"content": response["choices"][0]["text"]}}]
            }).encode())

    def do_get(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())

def run_server():
    RequestHandler.llm = Llama(model_path="{{MODEL_PATH}}")
    server = HTTPServer(("{{HOST}}", {{PORT}}), RequestHandler)
    print(f"Server running on http://{{HOST}}:{{PORT}}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
""";
