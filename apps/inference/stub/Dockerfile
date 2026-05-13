# Stub inference server for architecture validation.
# Uses Python stdlib only — no pip install needed, tiny image.
# Schedules on GPU nodes (via resource request in deployment.yaml) without
# requiring CUDA, proving Karpenter provisioning and KEDA scaling end-to-end.

FROM python:3.11-slim

WORKDIR /app
COPY server.py .

# Non-root user — required for PSS baseline enforcement
RUN useradd -m -u 1000 inference
USER inference

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["python", "server.py"]
