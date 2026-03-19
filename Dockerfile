FROM node:22-slim

RUN npm install -g @anthropic-ai/claude-code && \
    apt-get update && apt-get install -y git && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /home/claude && chmod 777 /home/claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/claude/.claude.json && \
    chmod 666 /home/claude/.claude.json

ENV HOME=/home/claude
WORKDIR /workspace
ENTRYPOINT ["claude"]
