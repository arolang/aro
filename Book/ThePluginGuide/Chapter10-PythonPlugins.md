# Chapter 10: Python Plugins

*"Life is short. Use Python."*

---

Python unlocks the most expansive ecosystem in programming. Machine learning, data science, natural language processing, web scraping—if it exists, there's a Python library for it. This chapter shows you how to bring Python's power to ARO, with a focus on LLM inference and AI workloads.

## 10.1 Why Python?

Python plugins excel at:

**Machine Learning**: TensorFlow, PyTorch, Transformers, scikit-learn—the entire ML ecosystem is Python-first. Want GPT inference in your ARO application? Python is the path.

**Data Science**: NumPy, Pandas, Matplotlib—tools that have defined how we work with data.

**Rapid Prototyping**: Python's dynamic nature enables quick experimentation. When you're not sure what you need, Python helps you figure it out.

**Library Breadth**: From web scraping (Beautiful Soup) to PDF processing (PyPDF2) to astronomy (Astropy)—Python has libraries for nearly every domain.

The trade-off is performance. Python is interpreted, with significant overhead compared to native code. But for many tasks—especially those involving external services or computationally expensive operations that dwarf interpreter overhead—Python is an excellent choice.

## 10.2 How Python Plugins Work

Unlike native plugins that load as dynamic libraries, Python plugins run out of process:

```
ARO Runtime → python3 -c <driver script> → stdout → ARO Runtime
```

Per call, ARO writes a small driver script, spawns `python3 -c` with it, and
reads the single JSON document the script prints:

```python
# What ARO actually runs, once per invocation
import sys, json, base64
sys.path.insert(0, '/path/to/Plugins/plugin-python-text/src')
from plugin import aro_action_analyze
input_json = base64.b64decode('...').decode('utf-8')
print(aro_action_analyze(input_json))
```

This architecture has implications:

**A fresh interpreter every call.** This is the one thing to internalise.
There is no long-lived Python process and no stdin/stdout dialogue. Every
action invocation and every qualifier invocation pays the full cost of
starting Python and importing your module, and every one of them starts with
empty globals. A module-level cache is a cache of exactly one call.

**Startup Overhead**: ~50–100 ms per call for a bare module, and far more once
a heavy library is imported at module scope — `import torch` alone can dominate.
Import expensive things lazily, inside the handler, so a call that does not
need them does not pay for them.

**Memory Isolation**: Python runs in its own memory space, and it is torn down
between calls. A crash in Python does not crash ARO; it surfaces as a plugin
error with the Python traceback attached.

**Timeouts**: A call that hangs is killed. The limit comes from
`RuntimeDefaults.pythonPluginTimeout`.

**Library Freedom**: Python uses its own package ecosystem. `pip install` works as expected.

## 10.3 Project Structure

```
Plugins/
└── plugin-python-transformer/
    ├── plugin.yaml
    ├── requirements.txt
    └── src/
        └── plugin.py
```

### plugin.yaml

```yaml
name: plugin-python-transformer
version: 1.0.0
description: "LLM inference using Hugging Face Transformers"
author: "Your Name"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
```

### requirements.txt

```
transformers>=4.36.0
torch>=2.0.0
accelerate>=0.25.0
sentencepiece>=0.1.99
```

## 10.4 The Python Plugin Interface

### aro_plugin_info()

`aro_plugin_info` is **required**. It returns plugin metadata as a dictionary that mirrors the unified info JSON schema used by all plugin languages:

```python
def aro_plugin_info() -> dict:
    """Return plugin metadata. REQUIRED."""
    return {
        "name": "plugin-python-transformer",
        "version": "1.0.0",
        "actions": [
            {
                "name": "Generate",
                "role": "own",
                "verbs": ["generate"],
                "prepositions": ["from", "with"],
                "description": "Generate text continuation using a language model"
            },
            {
                "name": "Summarize",
                "role": "own",
                "verbs": ["summarize"],
                "prepositions": ["from", "with"],
                "description": "Summarize a document"
            }
        ],
        "qualifiers": [
            {
                "name": "truncate",
                "inputTypes": ["String"],
                "accepts_parameters": True,
                "description": "Truncate a string to a maximum length"
            }
        ]
    }
```

The `actions` list now uses the same rich format as native plugins: each action declares its name, role, verbs, and prepositions. The flat `"actions": ["generate", "summarize"]` shorthand is still accepted for backward compatibility, but the structured form is preferred.

The `qualifiers` list can declare `"accepts_parameters": true` to indicate that
the qualifier accepts a `with { }` clause. Note the casing: `inputTypes` is
camelCase while `accepts_parameters` next to it is snake_case. That is
inconsistent and it is what the runtime reads — spell it `input_types` and the
declaration is ignored, leaving the qualifier accepting every type.

### aro_action_{name}(input_json: str) -> str

Each action is a function named `aro_action_{action_name}`:

```python
def aro_action_generate(input_json: str) -> str:
    """Generate text using a language model."""
    params = json.loads(input_json)

    # Primary value comes from "data" key
    prompt = params.get("data", params.get("prompt", ""))

    # Parameters from the ARO `with { }` clause arrive nested under "_with"
    with_params = params.get("_with", {})
    max_length = with_params.get("max_length", params.get("max_length", 100))

    # Execution context (requestId, featureSet, businessActivity) is under "_context"
    context = params.get("_context", {})

    # Process...
    return json.dumps({"generated_text": result})
```

The naming convention is important: `aro_action_` prefix + action name (lowercased, with hyphens replaced by underscores). Input parameters from the `with { }` clause are **nested under `"_with"`**, not flat-merged with the primary value.

### aro_plugin_qualifier(name: str, input_json: str) -> str

Qualifiers do **not** follow the `aro_action_` naming pattern. Actions get one
module function each; qualifiers all share a single dispatcher named
`aro_plugin_qualifier`, which receives the qualifier name as its first
argument:

```python
def aro_plugin_qualifier(name: str, input_json: str) -> str:
    """Dispatch a qualifier by name. One function for all qualifiers."""
    params = json.loads(input_json)
    value = params.get("value", "")
    with_params = params.get("_with", {})

    if name == "truncate":
        max_length = with_params.get("maxLength", 100)
        suffix = with_params.get("suffix", "...")
        if len(value) <= max_length:
            return json.dumps({"result": value})
        return json.dumps({"result": value[:max_length] + suffix})

    return json.dumps({"error": f"Unknown qualifier: {name}"})
```

Two rules the runtime enforces strictly:

**The response shape is `{"result": <value>}` or `{"error": "<message>"}`** —
nothing else. Returning the bare value (`json.dumps(value)`) fails with
*Plugin returned neither result nor error*, and wrapping twice
(`{"result": {"result": …}}`) binds the inner object instead of the value.

**A qualifier arrives under the name you declared.** `pick-random` reaches your
dispatcher as `pick-random` and `toHtml` as `toHtml`, so key your registry on
the declared spelling and look it up exactly — which is what the SDK's
`@qualifier` decorator does. ARO source stays case-insensitive: `<x:
Stats.TOHTML>` resolves the same qualifier, and your dispatcher is still asked
for `toHtml` (GitLab #553).

Actions are the other way round, and this catches people: an action's name
becomes a *function* name, and both the SDK and the runtime snake-case it, so
`Pick-Random` is dispatched as `aro_action_pick_random`.

### The Python Plugin SDK

Writing those module functions by hand is optional. `aro new plugin --lang
python` scaffolds against the `aro-plugin-sdk` package, which generates them
from decorated handlers:

```python
from typing import Any, Dict
from aro_plugin_sdk import AROInput, action, export_abi, plugin, qualifier, run

@plugin(name="plugin-python-text", version="1.0.0", handle="Text")
class TextPlugin:
    pass

@action(name="analyze", verbs=["analyze"], role="own",
        prepositions=["from"], description="Analyze text statistics.")
def handle_analyze(input: AROInput) -> Dict[str, Any]:
    return {"words": len(input.get("data", "").split())}

@qualifier(name="shout", description="Uppercase a string")
def qualifier_shout(input: AROInput) -> str:
    return input.get("value", "").upper()

# Generates aro_plugin_info, aro_action_analyze and aro_plugin_qualifier.
export_abi(globals())

if __name__ == "__main__":
    run()
```

Note what the qualifier handler returns: the **bare transformed value**. The
SDK's `export_abi` adds the `{"result": …}` wrapper for you. Return a dict —
as the SDK's own README and its `ok()` helper both do — and you get the
double-wrapped shape the runtime mis-binds (GitLab #551). Until that is
resolved, return bare values from `@qualifier` handlers.

The `run()` call at the bottom starts the SDK's persistent JSON-line loop. ARO
does not use it — it imports your module and calls one function, as shown
above — so it is harmless, but do not design around it.

## 10.5 Building an LLM Inference Plugin: Custom Actions

Let's build a complete LLM inference plugin using Hugging Face Transformers.

### Complete Implementation

```python
"""
ARO Plugin - LLM Inference with Transformers

This plugin provides text generation, summarization, and embeddings
using Hugging Face's transformer models.
"""

import json
import sys
from typing import Any, Dict, List, Optional
import warnings

# Suppress warnings during model loading
warnings.filterwarnings("ignore")

# Lazy imports for faster startup when not all features are used
_pipeline = None
_models = {}


def _get_pipeline():
    """Lazy import of transformers pipeline."""
    global _pipeline
    if _pipeline is None:
        from transformers import pipeline
        _pipeline = pipeline
    return _pipeline


def _load_model(task: str, model_name: Optional[str] = None):
    """Load or retrieve a cached model."""
    key = f"{task}:{model_name or 'default'}"
    if key not in _models:
        pipeline = _get_pipeline()

        if task == "text-generation":
            model = model_name or "gpt2"
            _models[key] = pipeline(task, model=model, device_map="auto")
        elif task == "summarization":
            model = model_name or "facebook/bart-large-cnn"
            _models[key] = pipeline(task, model=model, device_map="auto")
        elif task == "feature-extraction":
            model = model_name or "sentence-transformers/all-MiniLM-L6-v2"
            _models[key] = pipeline(task, model=model, device_map="auto")
        elif task == "text-classification":
            model = model_name or "distilbert-base-uncased-finetuned-sst-2-english"
            _models[key] = pipeline(task, model=model, device_map="auto")
        elif task == "question-answering":
            model = model_name or "distilbert-base-cased-distilled-squad"
            _models[key] = pipeline(task, model=model, device_map="auto")
        else:
            raise ValueError(f"Unknown task: {task}")

    return _models[key]


# ============================================================
# Plugin Interface
# ============================================================

def aro_plugin_info() -> Dict[str, Any]:
    """Return plugin metadata. REQUIRED."""
    return {
        "name": "plugin-python-transformer",
        "version": "1.0.0",
        "actions": [
            {
                "name": "Generate",
                "role": "own",
                "verbs": ["generate"],
                "prepositions": ["from", "with"],
                "description": "Generate text continuation using a language model"
            },
            {
                "name": "Summarize",
                "role": "own",
                "verbs": ["summarize"],
                "prepositions": ["from", "with"],
                "description": "Summarize a document"
            },
            {
                "name": "Embed",
                "role": "own",
                "verbs": ["embed"],
                "prepositions": ["from", "with"],
                "description": "Generate text embeddings"
            },
            {
                "name": "Classify",
                "role": "own",
                "verbs": ["classify"],
                "prepositions": ["from", "with"],
                "description": "Classify text sentiment or category"
            },
            {
                "name": "Answer",
                "role": "own",
                "verbs": ["answer"],
                "prepositions": ["from", "with"],
                "description": "Answer questions based on context"
            },
            {
                "name": "Models",
                "role": "own",
                "verbs": ["models"],
                "prepositions": ["from"],
                "description": "List available models"
            }
        ]
    }


# ============================================================
# Actions
# ============================================================

def aro_action_generate(input_json: str) -> str:
    """
    Generate text continuation using a language model.

    Input:
        - data: The text to continue (primary value)
        - _with.max_length: Maximum length of generated text (default: 100)
        - _with.temperature: Sampling temperature (default: 0.7)
        - _with.model: Model name (default: "gpt2")

    Output:
        - generated_text: The generated continuation
        - prompt: Original prompt
        - model: Model used
    """
    params = json.loads(input_json)
    prompt = params.get("data", params.get("prompt", ""))
    # Parameters from `with { }` are nested under "_with"
    with_params = params.get("_with", {})
    max_length = with_params.get("max_length", params.get("max_length", 100))
    temperature = with_params.get("temperature", params.get("temperature", 0.7))
    model_name = with_params.get("model", params.get("model"))

    if not prompt:
        return json.dumps({"error": "Missing 'prompt' field"})

    try:
        generator = _load_model("text-generation", model_name)
        result = generator(
            prompt,
            max_length=max_length,
            temperature=temperature,
            num_return_sequences=1,
            do_sample=True,
            pad_token_id=generator.tokenizer.eos_token_id
        )

        generated = result[0]["generated_text"]

        return json.dumps({
            "generated_text": generated,
            "prompt": prompt,
            "model": model_name or "gpt2",
            "max_length": max_length
        })

    except Exception as e:
        return json.dumps({"error": str(e)})


def aro_action_summarize(input_json: str) -> str:
    """
    Summarize text using a summarization model.

    Input:
        - data: The text to summarize (primary value)
        - _with.max_length: Maximum summary length (default: 130)
        - _with.min_length: Minimum summary length (default: 30)
        - _with.model: Model name (default: "facebook/bart-large-cnn")

    Output:
        - summary: The generated summary
        - input_length: Original text length
        - compression_ratio: How much the text was compressed
    """
    params = json.loads(input_json)
    text = params.get("data", params.get("text", ""))
    with_params = params.get("_with", {})
    max_length = with_params.get("max_length", params.get("max_length", 130))
    min_length = with_params.get("min_length", params.get("min_length", 30))
    model_name = with_params.get("model", params.get("model"))

    if not text:
        return json.dumps({"error": "Missing 'text' field"})

    try:
        summarizer = _load_model("summarization", model_name)
        result = summarizer(
            text,
            max_length=max_length,
            min_length=min_length,
            do_sample=False
        )

        summary = result[0]["summary_text"]
        compression = len(summary) / len(text) if text else 0

        return json.dumps({
            "summary": summary,
            "input_length": len(text),
            "output_length": len(summary),
            "compression_ratio": round(compression, 3),
            "model": model_name or "facebook/bart-large-cnn"
        })

    except Exception as e:
        return json.dumps({"error": str(e)})


def aro_action_embed(input_json: str) -> str:
    """
    Generate embeddings for text.

    Input:
        - data: Single text or list of texts to embed (primary value)
        - _with.model: Model name (default: "sentence-transformers/all-MiniLM-L6-v2")

    Output:
        - embeddings: List of embedding vectors
        - dimensions: Embedding dimensions
        - count: Number of texts embedded
    """
    params = json.loads(input_json)
    text = params.get("data", params.get("text", ""))
    with_params = params.get("_with", {})
    model_name = with_params.get("model", params.get("model"))

    if not text:
        return json.dumps({"error": "Missing 'text' field"})

    # Handle single string or list
    texts = [text] if isinstance(text, str) else text

    try:
        embedder = _load_model("feature-extraction", model_name)
        results = embedder(texts)

        # Average pooling for sentence embeddings
        embeddings = []
        for result in results:
            # result shape: (tokens, dimensions) - mean pool over tokens
            import numpy as np
            embedding = np.mean(result, axis=0).tolist()
            embeddings.append(embedding)

        dimensions = len(embeddings[0]) if embeddings else 0

        return json.dumps({
            "embeddings": embeddings,
            "dimensions": dimensions,
            "count": len(texts),
            "model": model_name or "sentence-transformers/all-MiniLM-L6-v2"
        })

    except Exception as e:
        return json.dumps({"error": str(e)})


def aro_action_classify(input_json: str) -> str:
    """
    Classify text sentiment or category.

    Input:
        - data: Text to classify (primary value)
        - _with.model: Model name (default: sentiment analysis model)

    Output:
        - label: Predicted label
        - score: Confidence score
        - all_scores: All label scores
    """
    params = json.loads(input_json)
    text = params.get("data", params.get("text", ""))
    with_params = params.get("_with", {})
    model_name = with_params.get("model", params.get("model"))

    if not text:
        return json.dumps({"error": "Missing 'text' field"})

    try:
        classifier = _load_model("text-classification", model_name)
        result = classifier(text, top_k=None)

        # Sort by score descending
        result = sorted(result, key=lambda x: x["score"], reverse=True)

        return json.dumps({
            "label": result[0]["label"],
            "score": round(result[0]["score"], 4),
            "all_scores": [
                {"label": r["label"], "score": round(r["score"], 4)}
                for r in result
            ],
            "text": text[:100] + "..." if len(text) > 100 else text,
            "model": model_name or "distilbert-base-uncased-finetuned-sst-2-english"
        })

    except Exception as e:
        return json.dumps({"error": str(e)})


def aro_action_answer(input_json: str) -> str:
    """
    Answer questions based on context.

    Input:
        - data: The question to answer (primary value)
        - _with.context: The context containing the answer
        - _with.model: Model name (default: DistilBERT QA model)

    Output:
        - answer: The extracted answer
        - score: Confidence score
        - start: Start position in context
        - end: End position in context
    """
    params = json.loads(input_json)
    with_params = params.get("_with", {})
    question = params.get("data", params.get("question", ""))
    context = with_params.get("context", params.get("context", ""))
    model_name = with_params.get("model", params.get("model"))

    if not question:
        return json.dumps({"error": "Missing 'question' field"})
    if not context:
        return json.dumps({"error": "Missing 'context' field"})

    try:
        qa = _load_model("question-answering", model_name)
        result = qa(question=question, context=context)

        return json.dumps({
            "answer": result["answer"],
            "score": round(result["score"], 4),
            "start": result["start"],
            "end": result["end"],
            "question": question,
            "model": model_name or "distilbert-base-cased-distilled-squad"
        })

    except Exception as e:
        return json.dumps({"error": str(e)})


def aro_action_models(input_json: str) -> str:
    """
    List available models and their status.

    Output:
        - loaded: List of currently loaded models
        - available: Default models for each task
    """
    return json.dumps({
        "loaded": list(_models.keys()),
        "available": {
            "text-generation": "gpt2",
            "summarization": "facebook/bart-large-cnn",
            "feature-extraction": "sentence-transformers/all-MiniLM-L6-v2",
            "text-classification": "distilbert-base-uncased-finetuned-sst-2-english",
            "question-answering": "distilbert-base-cased-distilled-squad"
        }
    })


# ============================================================
# Main Loop (for ARO subprocess communication)
# ============================================================

def main():
    """Main loop for processing ARO requests via stdin/stdout."""
    for line in sys.stdin:
        try:
            request = json.loads(line.strip())
            action = request.get("action", "")
            input_data = request.get("input", "{}")

            # Dispatch to action function
            func_name = f"aro_action_{action.replace('-', '_')}"
            if func_name in globals():
                result = globals()[func_name](input_data)
            else:
                result = json.dumps({"error": f"Unknown action: {action}"})

            print(result, flush=True)

        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid JSON: {e}"}), flush=True)
        except Exception as e:
            print(json.dumps({"error": f"Exception: {e}"}), flush=True)


if __name__ == "__main__":
    # If run directly, enter the ARO communication loop
    if len(sys.argv) > 1 and sys.argv[1] == "--aro":
        main()
    else:
        # Testing mode
        print("Plugin Info:")
        print(json.dumps(aro_plugin_info(), indent=2))

        print("\n\nText Generation:")
        result = aro_action_generate(json.dumps({
            "prompt": "The future of AI is",
            "max_length": 50
        }))
        print(result)
```

### requirements.txt

```
transformers>=4.36.0
torch>=2.0.0
accelerate>=0.25.0
numpy>=1.24.0
sentencepiece>=0.1.99
```

## 10.6 Using the LLM Plugin in ARO

With custom actions registered, use native ARO syntax for AI operations:

```aro
(Application-Start: AI Demo) {
    Log "Starting LLM inference demo..." to the <console>.

    (* Generate text using custom action *)
    Generate the <generated> from "The key to successful software development is" with {
        max_length: 100,
        temperature: 0.8
    }.
    Log "Generated: " ++ <generated: generated_text> to the <console>.

    (* Summarize a long document using custom action *)
    Create the <document> with "Machine learning is a subset of artificial intelligence (AI) that provides systems the ability to automatically learn and improve from experience without being explicitly programmed. Machine learning focuses on the development of computer programs that can access data and use it to learn for themselves. The process of learning begins with observations or data, such as examples, direct experience, or instruction, in order to look for patterns in data and make better decisions in the future based on the examples that we provide.".

    Summarize the <summary> from <document> with { max_length: 50 }.
    Log "Summary: " ++ <summary: summary> to the <console>.

    (* Classify sentiment using custom action *)
    Classify the <sentiment> from "This product exceeded all my expectations! Highly recommended.".
    Log "Sentiment: " ++ <sentiment: label> to the <console>.
    Log "Confidence: " ++ <sentiment: score> to the <console>.

    (* Question answering using custom action *)
    Create the <context> with "ARO is a domain-specific language for expressing business logic. It was created in 2026 and uses an Action-Result-Object syntax pattern.".

    Answer the <answer> from "What syntax pattern does ARO use?" with {
        context: <context>
    }.
    Log "Answer: " ++ <answer: answer> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

The `<Generate>`, `<Summarize>`, `<Classify>`, and `<Answer>` actions integrate seamlessly with ARO's syntax, making AI operations feel native!

## 10.7 Performance Optimization

### Model Caching

The `_models` dict above caches within a single call — and a single call is all
the process lives for. Because ARO spawns a fresh `python3` per invocation,
this pattern does **not** amortise loading across calls the way it would in a
long-lived server:

```python
_models = {}  # Global cache — empty again on the next invocation

def _load_model(task: str, model_name: Optional[str] = None):
    key = f"{task}:{model_name or 'default'}"
    if key not in _models:
        # Slow. Happens on EVERY ARO statement that calls this plugin.
        _models[key] = pipeline(task, model=model_name, device_map="auto")
    return _models[key]
```

It still earns its keep inside one call — an action that classifies a batch
loads the model once rather than per item — and it costs nothing. But a plugin
whose model takes thirty seconds to load takes thirty seconds *per statement*.
If that is unacceptable, run the model behind a long-lived process (an HTTP
server, or a socket daemon started from `Application-Start`) and make the
plugin a thin client.

### Batch Processing

For multiple items, batch requests to reduce overhead:

```python
def aro_action_batch_classify(input_json: str) -> str:
    """Classify multiple texts in a single call."""
    params = json.loads(input_json)
    texts = params.get("texts", [])

    if not texts:
        return json.dumps({"error": "Missing 'texts' array"})

    classifier = _load_model("text-classification")

    # Process all at once - much faster than individual calls
    results = classifier(texts)

    return json.dumps({
        "results": [
            {"text": text[:50], "label": r["label"], "score": round(r["score"], 4)}
            for text, r in zip(texts, results)
        ],
        "count": len(texts)
    })
```

### GPU Acceleration

Enable GPU with `device_map="auto"`:

```python
from transformers import pipeline

# Automatically uses GPU if available
generator = pipeline("text-generation", model="gpt2", device_map="auto")
```

For explicit GPU control:

```python
import torch

device = "cuda" if torch.cuda.is_available() else "cpu"
generator = pipeline("text-generation", model="gpt2", device=device)
```

### Quantization for Smaller Models

Load quantized models for faster inference:

```python
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

quantization_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_compute_dtype=torch.float16
)

model = AutoModelForCausalLM.from_pretrained(
    "meta-llama/Llama-2-7b-chat-hf",
    quantization_config=quantization_config,
    device_map="auto"
)
```

## 10.8 Error Handling

Python plugins should never crash. Always catch exceptions:

```python
def aro_action_generate(input_json: str) -> str:
    try:
        params = json.loads(input_json)
        # ... processing ...
        return json.dumps({"result": result})

    except json.JSONDecodeError as e:
        return json.dumps({
            "error": "Invalid JSON input",
            "details": str(e)
        })
    except KeyError as e:
        return json.dumps({
            "error": f"Missing required field: {e}",
            "received_fields": list(params.keys())
        })
    except torch.cuda.OutOfMemoryError:
        return json.dumps({
            "error": "GPU out of memory",
            "suggestion": "Try reducing max_length or batch size"
        })
    except Exception as e:
        return json.dumps({
            "error": "Unexpected error",
            "type": type(e).__name__,
            "message": str(e)
        })
```

## 10.9 Working with Dependencies

### Virtual Environments

Create a dedicated environment for your plugin:

```bash
# Create environment
python3 -m venv Plugins/plugin-python-transformer/.venv

# Activate
source Plugins/plugin-python-transformer/.venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### Specifying Python Version

In `plugin.yaml`:

```yaml
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
```

ARO will check Python version compatibility at load time.

### Heavy Dependencies

For large dependencies (PyTorch can be 2GB+), consider:

1. **Documentation**: Note system requirements in README
2. **Lazy Loading**: Import heavy libraries only when needed
3. **Optional Features**: Make some functionality optional

```python
# Lazy import pattern
_torch = None

def _get_torch():
    global _torch
    if _torch is None:
        import torch
        _torch = torch
    return _torch
```

## 10.10 Text Processing Plugin Example

Here's a simpler example without ML dependencies:

```python
"""
ARO Plugin - Text Processing

Simple text processing without heavy dependencies.
"""

import json
import re
from typing import Dict, Any
import hashlib
from collections import Counter


def aro_plugin_info() -> Dict[str, Any]:
    return {
        "name": "plugin-python-text",
        "version": "1.0.0",
        "actions": [
            {"name": "Analyze", "role": "own", "verbs": ["analyze"], "prepositions": ["from"]},
            {"name": "ExtractEmails", "role": "own", "verbs": ["extractemails"], "prepositions": ["from"]},
            {"name": "ExtractURLs", "role": "own", "verbs": ["extracturls"], "prepositions": ["from"]},
            {"name": "Hash", "role": "own", "verbs": ["hash"], "prepositions": ["from", "with"]},
            {"name": "Diff", "role": "own", "verbs": ["diff"], "prepositions": ["from", "with"]}
        ]
    }


def aro_action_analyze(input_json: str) -> str:
    """Analyze text statistics."""
    params = json.loads(input_json)
    text = params.get("text", params.get("data", ""))

    if not text:
        return json.dumps({"error": "Missing 'text' field"})

    words = text.split()
    word_freq = Counter(words)

    return json.dumps({
        "characters": len(text),
        "characters_no_spaces": len(text.replace(" ", "")),
        "words": len(words),
        "sentences": len(re.findall(r'[.!?]+', text)),
        "paragraphs": len(text.split('\n\n')),
        "unique_words": len(set(words)),
        "average_word_length": round(sum(len(w) for w in words) / len(words), 2) if words else 0,
        "most_common": word_freq.most_common(5)
    })


def aro_action_extract_emails(input_json: str) -> str:
    """Extract email addresses from text."""
    params = json.loads(input_json)
    text = params.get("text", params.get("data", ""))

    pattern = r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
    emails = list(set(re.findall(pattern, text)))

    return json.dumps({
        "emails": emails,
        "count": len(emails)
    })


def aro_action_extract_urls(input_json: str) -> str:
    """Extract URLs from text."""
    params = json.loads(input_json)
    text = params.get("text", params.get("data", ""))

    pattern = r'https?://[^\s<>"{}|\\^`\[\]]+'
    urls = list(set(re.findall(pattern, text)))

    return json.dumps({
        "urls": urls,
        "count": len(urls)
    })


def aro_action_hash(input_json: str) -> str:
    """Generate various hashes of text."""
    params = json.loads(input_json)
    text = params.get("data", params.get("text", ""))
    with_params = params.get("_with", {})
    algorithm = with_params.get("algorithm", params.get("algorithm", "sha256"))

    if not text:
        return json.dumps({"error": "Missing 'text' field"})

    data = text.encode('utf-8')

    hashes = {
        "md5": hashlib.md5(data).hexdigest(),
        "sha1": hashlib.sha1(data).hexdigest(),
        "sha256": hashlib.sha256(data).hexdigest(),
        "sha512": hashlib.sha512(data).hexdigest()
    }

    if algorithm == "all":
        return json.dumps({"hashes": hashes})
    elif algorithm in hashes:
        return json.dumps({
            "hash": hashes[algorithm],
            "algorithm": algorithm
        })
    else:
        return json.dumps({"error": f"Unknown algorithm: {algorithm}"})


def aro_action_diff(input_json: str) -> str:
    """Compare two texts and show differences."""
    params = json.loads(input_json)
    text1 = params.get("text1", "")
    text2 = params.get("text2", "")

    if not text1 or not text2:
        return json.dumps({"error": "Missing 'text1' or 'text2' field"})

    import difflib
    diff = list(difflib.unified_diff(
        text1.splitlines(keepends=True),
        text2.splitlines(keepends=True),
        fromfile='text1',
        tofile='text2'
    ))

    return json.dumps({
        "diff": ''.join(diff),
        "identical": text1 == text2,
        "similarity": round(difflib.SequenceMatcher(None, text1, text2).ratio(), 4)
    })
```

## 10.11 When to Use Python

Python plugins are ideal when:

- **ML/AI workloads**: Transformers, TensorFlow, PyTorch
- **Data processing**: Pandas, NumPy operations
- **Quick prototyping**: Testing ideas before native implementation
- **Library availability**: When a Python library has no native equivalent
- **Computation dominates**: When the actual work takes seconds

Avoid Python when:

- **High-frequency calls**: Sub-millisecond response times needed
- **Low latency critical**: First-call overhead is unacceptable
- **Simple operations**: Native code would be more efficient

## 10.12 Summary

Python plugins open the entire Python ecosystem to ARO:

- **`aro_plugin_info()`** is **required**—returns a dict with structured action declarations matching the unified schema
- **`aro_action_{name}(input_json: str) -> str`** for each action the plugin provides
- **`aro_plugin_qualifier(name: str, input_json: str) -> str`** — one dispatcher for all qualifiers, not one function each. It must return `{"result": <value>}` or `{"error": "..."}`; the qualifier name arrives exactly as declared, so look it up exactly (unlike actions, whose names are snake-cased into `aro_action_<name>`)
- **Input JSON**: primary value under `"data"`, `with { }` parameters nested under `"_with"`, execution context under `"_context"`
- **Communication (interpreter mode)**: a fresh `python3 -c` process per call. No persistent process, no stdin/stdout dialogue, no state carried between calls — design for statelessness and import heavy libraries lazily
- **Communication (binary mode)**: In-process execution via embedded `libpython3` — no subprocess, no Python installation needed on the target machine. `aro build` links `libpython3` into the binary and embeds plugin source as string constants.
- **Dependencies**: Standard `requirements.txt` with pip. In binary mode, dependencies are installed at build time and bundled.
- **ML/AI**: Hugging Face Transformers for LLM inference
- **Performance**: Model caching, batching, GPU acceleration
- **Error handling**: Always catch exceptions, return JSON errors

The combination of ARO's clear business logic and Python's ML capabilities creates a powerful platform for AI-enhanced applications.

Next, we'll explore how to manage plugins with external dependencies in any language.

