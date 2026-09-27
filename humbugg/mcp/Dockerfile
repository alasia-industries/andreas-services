# The hosted MCP server (infra/modules/mcp): uvicorn serving humbugg_mcp.hosted:app,
# turned into a Lambda by the Lambda Web Adapter extension. The MCP Apps pages
# (humbugg_mcp/ui/*.html) are built output — run `npm ci && npm run build` in
# widgets/ before `docker build`, or the server refuses to start.
FROM public.ecr.aws/docker/library/python:3.12-slim

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY pyproject.toml ./
COPY humbugg_mcp ./humbugg_mcp
RUN test -f humbugg_mcp/ui/draw-review.html && test -f humbugg_mcp/ui/assignment.html && test -f humbugg_mcp/ui/wishlist.html && test -f humbugg_mcp/ui/groups.html && test -f humbugg_mcp/ui/group.html \
 && pip install --no-cache-dir ".[hosted]" && rm -rf /root/.cache

CMD ["uvicorn", "humbugg_mcp.hosted:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
