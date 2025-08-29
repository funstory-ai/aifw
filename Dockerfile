ARG BASE_IMAGE=python:3.13-slim
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AIFW_WORK_DIR=/data/aifw \
    XDG_CONFIG_HOME=/data/config

WORKDIR /opt/aifw

# Build-time profile to control spaCy models
ARG SPACY_PROFILE=minimal

# Copy requirements first for better cache
COPY services/requirements.txt /opt/aifw/services/requirements.txt
COPY cli/requirements.txt /opt/aifw/cli/requirements.txt

RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r /opt/aifw/services/requirements.txt && \
    pip install --no-cache-dir -r /opt/aifw/cli/requirements.txt

# Install spaCy models per profile
RUN set -e; \
    python -m spacy download en_core_web_sm; \
    python -m spacy download zh_core_web_sm; \
    python -m spacy download xx_ent_wiki_sm; \
    if [ "$SPACY_PROFILE" = "fr" ] || [ "$SPACY_PROFILE" = "multi" ]; then python -m spacy download fr_core_news_sm || true; fi; \
    if [ "$SPACY_PROFILE" = "de" ] || [ "$SPACY_PROFILE" = "multi" ]; then python -m spacy download de_core_news_sm || true; fi; \
    if [ "$SPACY_PROFILE" = "ja" ] || [ "$SPACY_PROFILE" = "multi" ]; then python -m spacy download ja_core_news_sm || true; fi

# Copy only necessary project files to minimize image size
COPY cli/*.py /opt/aifw/cli/
COPY aifw/*.py /opt/aifw/aifw/
COPY services/app/*.py services/app/*.json services/fake_llm/*.py /opt/aifw/services/app/
# Copy default config template (no secrets)
COPY assets/*.yaml assets/*.json /opt/aifw/assets/

# Ensure runtime dirs; no API keys baked in image
RUN mkdir -p ${AIFW_WORK_DIR} /var/log/aifw && \
    chmod -R 777 ${AIFW_WORK_DIR} /var/log/aifw

# Entrypoint: prepare work dir and default config if missing
RUN printf '#!/bin/sh\nset -e\n: "${AIFW_WORK_DIR:=/data/aifw}"\nmkdir -p "${AIFW_WORK_DIR}"\nif [ ! -f "${AIFW_WORK_DIR}/aifw.yaml" ] && [ -f "/opt/aifw/assets/aifw.yaml" ]; then\n  cp /opt/aifw/assets/aifw.yaml "${AIFW_WORK_DIR}/aifw.yaml";\nfi\nexport PYTHONPATH="/opt/aifw:${PYTHONPATH:-}"\nexec "$@"\n' > /usr/local/bin/aifw-entrypoint.sh && \
    chmod +x /usr/local/bin/aifw-entrypoint.sh

# Set a sane default; append happens in entrypoint using ${PYTHONPATH:-}
ENV PYTHONPATH=/opt/aifw

# Expose default service port
EXPOSE 8844

ENTRYPOINT ["/usr/local/bin/aifw-entrypoint.sh"]
# Default: run the OneAIFW in interactive mode; user must mount api key file and optionally override config
CMD ["/bin/bash"]
