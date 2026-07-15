# manifests/backend/app/Dockerfile
# Multi-stage build: keeps the runtime image lean.
# The builder stage installs wheels; the runtime stage has no build tools.
 
FROM python:3.12-slim AS builder
 
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt
 
 
FROM python:3.12-slim AS runtime
 
# Don't run as root — security best practice, required by many admission controllers
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
 
WORKDIR /app
 
# Copy pre-built wheels from builder (avoids pip in runtime image)
COPY --from=builder /root/.local /home/appuser/.local
COPY app.py .
 
RUN chown -R appuser:appgroup /app
 
USER appuser
 
ENV PATH="/home/appuser/.local/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
 
EXPOSE 8000
 
# 1 worker: endpoints run as plain `def` (see app.py), so FastAPI already
# offloads blocking DB calls to its own thread pool instead of the event
# loop — concurrency comes from that, not from OS-level multiprocessing.
# Horizontal scaling is HPA's job (backend-hpa); running multiple workers
# per pod on top of that just splits the pod's CPU limit into starved
# fractions instead of adding real parallelism.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--access-log", "--log-level", "info"]
