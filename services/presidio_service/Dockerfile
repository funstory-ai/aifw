FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY ./app /app/app
COPY requirements.txt /app/requirements.txt

RUN pip install --upgrade pip &&     pip install --no-cache-dir -r /app/requirements.txt

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
