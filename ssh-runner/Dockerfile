# aihub-ssh: ssh/scp runner for the Open WebUI "Remote Shell" tool (docs/13-remote-shell.md)
FROM python:3.12-alpine
RUN apk add --no-cache openssh-client tzdata
# Same UID/GID as the owner of /srv/ai/ssh so ssh accepts the key (it refuses keys owned by someone else)
ARG UID=1000
ARG GID=1000
RUN addgroup -g "$GID" aihub && adduser -D -u "$UID" -G aihub -h /home/aihub aihub
COPY app.py /app/app.py
USER aihub
ENV PYTHONUNBUFFERED=1
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:8022/health || exit 1
ENTRYPOINT ["python3", "/app/app.py"]
CMD ["serve"]
