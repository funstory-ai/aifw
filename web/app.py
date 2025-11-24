#!/usr/bin/env python3
"""
AIFW Web Module
Provides a web interface for the AIFW project with masking functionality.
"""

from flask import Flask, render_template, request, jsonify
import os
import sys

# Add cli/python to path to import AIFW modules
sys.path.append(os.path.join(os.path.dirname(__file__), '..', 'cli', 'python'))


try:
    from services.app.one_aifw_api import OneAIFWAPI
except ImportError as e:
    print(f"Warning: Could not import AIFW modules: {e}")
    print("Make sure you're running from the correct directory and py-origin is available")
    OneAIFWAPI = None

app = Flask(__name__)

# Initialize AIFW API
aifw_api = None

def initialize_aifw():
    """Initialize AIFW components"""
    global aifw_api
    try:
        if OneAIFWAPI:
            aifw_api = OneAIFWAPI()
            return True
    except Exception as e:
        print(f"Error initializing AIFW: {e}")
    return False

# Initialize on startup
initialize_aifw()

@app.route('/')
def index():
    """Main page with project introduction and input form"""
    return render_template('index.html')

@app.route('/api/health')
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "ok",
        "aifw_available": aifw_api is not None
    })

@app.route('/api/mask', methods=['POST'])
def mask_text():
    """API endpoint to mask/anonymize text"""
    try:
        data = request.get_json()
        if not data or 'text' not in data:
            return jsonify({"error": "Missing 'text' field"}), 400
        
        text = data['text']
        language = data.get('language', 'auto')
        
        if not text.strip():
            return jsonify({"error": "Text cannot be empty"}), 400
        
        # Perform masking via OneAIFWAPI (uses aifw-py under the hood)
        result = aifw_api.mask_text(text=text, language=language)
        
        return jsonify({
            "original_text": text,
            "anonymized_text": result["text"],
            # maskMeta is base64-encoded binary meta; keep name for backward UI compat
            "placeholders_map": result["maskMeta"],
            "language": language
        })
        
    except Exception as e:
        return jsonify({"error": f"Anonymization failed: {str(e)}"}), 500

@app.route('/api/restore', methods=['POST'])
def restore_text():
    """API endpoint to restore anonymized text"""
    try:
        data = request.get_json()
        if not data or 'text' not in data or 'placeholders_map' not in data:
            return jsonify({"error": "Missing 'text' or 'placeholders_map' field"}), 400
        
        text = data['text']
        # For new aifw-py flow, placeholders_map actually carries base64-encoded maskMeta bytes
        mask_meta_b64 = data['placeholders_map']
        
        # Perform restoration via OneAIFWAPI (expects base64 or raw bytes)
        restored_text = aifw_api.restore_text(text=text, mask_meta=mask_meta_b64)
        
        return jsonify({
            "anonymized_text": text,
            "restored_text": restored_text,
            "placeholders_map": mask_meta_b64
        })
        
    except Exception as e:
        return jsonify({"error": f"Restoration failed: {str(e)}"}), 500

@app.route('/api/analyze', methods=['POST'])
def analyze_text():
    """API endpoint to analyze text for PII entities"""
    try:
        data = request.get_json()
        if not data or 'text' not in data:
            return jsonify({"error": "Missing 'text' field"}), 400
        
        text = data['text']
        language = data.get('language', 'auto')
        
        if not aifw_api:
            return jsonify({"error": "AIFW API not available"}), 500
        
        # Perform analysis via OneAIFWAPI get_pii_entities
        entities = aifw_api.get_pii_entities(text=text, language=language)
        return jsonify({
            "text": text,
            "language": language,
            "entities": entities
        })
        
    except Exception as e:
        return jsonify({"error": f"Analysis failed: {str(e)}"}), 500

@app.route('/api/call', methods=['POST'])
def call_llm():
    """API endpoint to call LLM with anonymization"""
    try:
        data = request.get_json()
        if not data or 'text' not in data:
            return jsonify({"error": "Missing 'text' field"}), 400
        
        text = data['text']
        api_key_file = data.get('api_key_file')
        model = data.get('model')
        temperature = data.get('temperature', 0.0)
        
        if not aifw_api:
            return jsonify({"error": "AIFW API not available"}), 500
        
        # Call AIFW API
        result = aifw_api.call(
            text=text,
            api_key_file=api_key_file,
            model=model,
            temperature=temperature
        )
        
        return jsonify({
            "original_text": text,
            "result": result,
            "model": model,
            "temperature": temperature
        })
        
    except Exception as e:
        return jsonify({"error": f"LLM call failed: {str(e)}"}), 500

if __name__ == '__main__':
    print("Starting AIFW Web Module...")
    print(f"AIFW API available: {aifw_api is not None}")
    
    app.run(debug=False, host='0.0.0.0', port=5001)
