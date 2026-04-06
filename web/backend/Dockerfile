FROM python:3.11-slim

WORKDIR /app

COPY pyproject.toml ./
RUN pip install --no-cache-dir .

COPY app/ app/
COPY migrations/ migrations/
COPY scripts/ scripts/
RUN mkdir -p uploads

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
