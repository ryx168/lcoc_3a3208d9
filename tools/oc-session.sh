#!/bin/bash
# Run the OpenCart admin behind the Cloudflare tunnel until it goes idle.
# Idle is measured by admin566 requests (a person editing), not scanner noise.
# A web FILE MANAGER (filebrowser) runs alongside over a throwaway cloudflared
# quick tunnel, rooted at the OpenCart webroot, so the hub's 檔案 button can edit
# the store files; its URL is published to the files-session branch for the hub.
# Edits persist via the normal oc-save (webroot -> app.tar.gz -> R2).
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}/webroot"
WEBROOT="$PWD"

# PHP built-in server (E_DEPRECATED/E_NOTICE silenced - 1.5.4 on PHP 5.6 is noisy)
php -d error_reporting="E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_STRICT" \
    -d display_errors=0 -S 127.0.0.1:8080 router.php >/tmp/php.log 2>&1 &
sleep 3
echo "php -S started; local admin probe:"
curl -s -o /dev/null -w "  /admin566/ -> %{http_code}\n" "http://127.0.0.1:8080/admin566/index.php?route=common/login" || true

# cloudflared with the named-tunnel token
if [ -n "${TUNNEL_TOKEN:-}" ]; then
  curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x /tmp/cloudflared
  /tmp/cloudflared tunnel --no-autoupdate --loglevel info run --token "$TUNNEL_TOKEN" >/tmp/cfd.log 2>&1 &
  echo "cloudflared started; editor at https://${EDIT_HOST}/admin566/"
else
  echo "no TUNNEL_TOKEN - local only"
fi

# ---- File manager (filebrowser) over a quick tunnel -----------------------
# Best-effort and isolated: a failure here must never take down the admin tunnel.
echo "::group::File manager"
FB_URL=""
{
  [ -x /tmp/cloudflared ] || { curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; chmod +x /tmp/cloudflared; }
  curl -fsSL --retry 6 --retry-all-errors --retry-delay 3 -o /tmp/fb.tar.gz \
    https://github.com/filebrowser/filebrowser/releases/download/v2.27.0/linux-amd64-filebrowser.tar.gz
  tar xzf /tmp/fb.tar.gz -C /tmp filebrowser 2>/dev/null
  sudo mv /tmp/filebrowser /usr/local/bin/filebrowser && sudo chmod +x /usr/local/bin/filebrowser
  FB_DB=/tmp/filebrowser.db
  filebrowser config init -d "$FB_DB" --root "$WEBROOT" >/tmp/fb-init.log 2>&1
  # No-login web UI: already gated by the hub login + the random one-time URL.
  filebrowser config set -d "$FB_DB" --auth.method=noauth >>/tmp/fb-init.log 2>&1
  filebrowser users add -d "$FB_DB" admin "${FB_PASS:-changeme}" --perm.admin >/tmp/fb-user.log 2>&1 || true
  setsid nohup filebrowser -d "$FB_DB" -a 127.0.0.1 -p 8090 --root "$WEBROOT" >/tmp/filebrowser.log 2>&1 < /dev/null &
  setsid nohup /tmp/cloudflared tunnel --url http://127.0.0.1:8090 --no-autoupdate >/tmp/fbcf.log 2>&1 < /dev/null &
  for i in $(seq 1 20); do
    sleep 2
    FB_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/fbcf.log | head -1 || true)
    [ -n "$FB_URL" ] && break
  done
} || true
echo "  file manager: ${FB_URL:-unavailable}"
echo "::endgroup::"

# Publish the file-manager URL for the hub on branch files-session.
if [ -n "$FB_URL" ]; then
  json=$(printf '{"domain":"%s","url":"%s","since":"%s"}\n' "${SITE_HOST:-}" "$FB_URL" "$(date -u +%FT%TZ)")
  blob=$(printf '%s' "$json" | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tfiles.json\n' "$blob" | git mktree)
  commit=$(git -c user.email=superesolutions@gmail.com -c user.name="conan editor" commit-tree "$tree" -m "files $(date -u +%FT%TZ)")
  git push -q -f origin "$commit:refs/heads/files-session" 2>/dev/null && echo "  file session published" || echo "  file session publish failed (check contents:write)"
fi

IDLE_MIN="${IDLE_MINUTES:-15}"
idle_limit=$(( IDLE_MIN * 60 ))
adm() { grep -c "admin566" /tmp/php.log 2>/dev/null || echo 0; }
fbh() { grep -cE '"(GET|POST|PUT|PATCH|DELETE) ' /tmp/filebrowser.log 2>/dev/null || echo 0; }
last_count=$(adm); last_fb=$(fbh); last_active=$(date +%s)
echo "watching for idle (${IDLE_MIN} min of no admin/file activity)"
MAX=$(( 340 * 60 )); start=$(date +%s)
while true; do
  sleep 20
  now=$(date +%s)
  c=$(adm); f=$(fbh)
  if [ "$c" != "$last_count" ] || [ "$f" != "$last_fb" ]; then last_count=$c; last_fb=$f; last_active=$now; fi
  idle=$(( now - last_active ))
  [ $idle -ge $idle_limit ] && { echo "idle ${idle}s >= ${idle_limit}s - stopping"; break; }
  [ $(( now - start )) -ge $MAX ] && { echo "max session time - stopping"; break; }
done
echo "session ended (admin requests seen: $(adm))"
# Clear the published file-manager URL so the hub stops showing a dead tunnel.
git push -q origin --delete files-session 2>/dev/null || true
