// Shared password-gate helper for sender.html and receiver.html. The server only
// enforces a password when STREAM_PASSWORD is set in its environment — when it
// isn't, the handshake succeeds regardless of what's sent here.
function createAuthenticatedSocket() {
  const STORAGE_KEY = 'stream_app_password';
  let overlay = null;

  function getStoredPassword() {
    try { return localStorage.getItem(STORAGE_KEY) || ''; } catch (e) { return ''; }
  }

  function storePassword(password) {
    try { localStorage.setItem(STORAGE_KEY, password); } catch (e) {}
  }

  function showPasswordPrompt(socket, errorMessage) {
    if (overlay) {
      overlay.querySelector('.auth-error').textContent = errorMessage || '';
      return;
    }
    overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.88);display:flex;' +
      'flex-direction:column;align-items:center;justify-content:center;z-index:9999;' +
      'font-family:-apple-system,system-ui,sans-serif;color:#eee;padding:24px;box-sizing:border-box;';
    overlay.innerHTML =
      '<div style="max-width:340px;width:100%;text-align:center;">' +
      '<div style="font-size:1.1rem;margin-bottom:16px;">This stream requires a password</div>' +
      '<input type="password" class="auth-input" style="width:100%;min-height:48px;font-size:1rem;' +
      'border-radius:8px;border:1px solid #555;padding:8px 12px;box-sizing:border-box;' +
      'background:#1e1e22;color:#eee;" />' +
      '<div class="auth-error" style="color:#ff6b6b;font-size:0.85rem;margin-top:8px;min-height:1.2em;">' +
      (errorMessage || '') + '</div>' +
      '<button class="auth-submit" style="width:100%;min-height:48px;margin-top:12px;border:none;' +
      'border-radius:8px;background:#2d7ef7;color:#fff;font-size:1rem;font-weight:600;cursor:pointer;">' +
      'Connect</button></div>';
    document.body.appendChild(overlay);

    const input = overlay.querySelector('.auth-input');
    const submit = () => {
      const password = input.value;
      storePassword(password);
      socket.auth = { password };
      socket.connect();
    };
    overlay.querySelector('.auth-submit').addEventListener('click', submit);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
    input.focus();
  }

  function hidePasswordPrompt() {
    if (overlay) {
      overlay.remove();
      overlay = null;
    }
  }

  const socket = io({ auth: { password: getStoredPassword() } });

  socket.on('connect_error', (err) => {
    if (err && err.message === 'Incorrect password') {
      showPasswordPrompt(socket, overlay ? 'Incorrect password — try again' : '');
    }
  });

  socket.on('connect', hidePasswordPrompt);

  return socket;
}
