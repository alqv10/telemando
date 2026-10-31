const http = require("http");
const https = require("https");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");
const crypto = require("crypto");
const { spawn, execFileSync } = require("child_process");

const PORT = Number(process.env.PORT) || 7070;
const DRY = process.env.TELEMANDO_DRY === "1";
const USE_HTTPS = process.argv.includes("--https");

// El token se guarda en disco: si cambiara en cada arranque, el link que
// quedo guardado en el telefono dejaria de servir.
const tokenFile = path.join(__dirname, "token.txt");
const TOKEN =
  process.env.TELEMANDO_TOKEN ||
  (fs.existsSync(tokenFile)
    ? fs.readFileSync(tokenFile, "utf8").trim()
    : (() => {
        const t = crypto.randomBytes(8).toString("hex");
        fs.writeFileSync(tokenFile, t);
        return t;
      })());

// En DRY no se toca el escritorio: lo usa test.js.
const helper = DRY
  ? null
  : spawn(
      "powershell",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(__dirname, "helper.ps1")],
      { stdio: ["pipe", "pipe", "inherit"] }
    );

const ACTIONS = new Set([
  "move", "moveto", "click", "dblclick", "rclick", "mclick", "down", "up",
  "scroll", "hscroll", "vk", "keys", "vol", "mute", "output", "bright",
  "app", "open", "focus", "closewin", "clip", "sys",
]);

let nextId = 1;
const pending = new Map();

if (helper) {
  // Las respuestas vuelven por stdout: "res <id> <base64>".
  readline.createInterface({ input: helper.stdout }).on("line", (line) => {
    const [tag, id, payload] = line.split(" ");
    if (tag !== "res") return;
    const waiting = pending.get(id);
    if (!waiting) return;
    pending.delete(id);
    waiting(Buffer.from(payload || "", "base64"));
  });
  helper.on("exit", (code) => {
    console.error(`\n  El motor de PowerShell se cerró (código ${code}). Reiniciá telemando.\n`);
    process.exitCode = 1;
  });
}

function fire(line) {
  const verb = line.split(" ", 1)[0];
  if (!ACTIONS.has(verb) || /[\r\n]/.test(line)) return false;
  // "open" es el unico que recibe texto libre: solo http(s), nada de rutas
  // ni protocolos raros que Start-Process ejecutaria.
  if (verb === "open" && !/^open https?:\/\/[^\s"'|&;]+$/.test(line)) return false;
  if (helper) helper.stdin.write(`- ${line}\n`);
  return true;
}

// 20 s porque el arranque en frio es lento: el helper compila el C# de
// CoreAudio con Add-Type antes de atender la primera orden.
function ask(line, ms = 20000) {
  return new Promise((resolve, reject) => {
    const id = String(nextId++);
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("timeout"));
    }, ms);
    pending.set(id, (buf) => {
      clearTimeout(timer);
      resolve(buf);
    });
    helper.stdin.write(`${id} ${line}\n`);
  });
}

const STATIC = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/manifest.webmanifest": ["manifest.webmanifest", "application/manifest+json"],
  "/sw.js": ["sw.js", "text/javascript"],
  "/icon-192.png": ["icon-192.png", "image/png"],
  "/icon-512.png": ["icon-512.png", "image/png"],
  "/icon.svg": ["icon.svg", "image/svg+xml"],
};

async function handle(req, res) {
  const [url, query] = req.url.split("?");

  // La cascara es publica: sin el token no hace absolutamente nada.
  const asset = STATIC[url];
  if (req.method === "GET" && asset) {
    try {
      const body = fs.readFileSync(path.join(__dirname, asset[0]));
      res.writeHead(200, { "content-type": asset[1], "cache-control": "no-cache" });
      return res.end(body);
    } catch {
      res.writeHead(404);
      return res.end();
    }
  }

  if (req.headers["x-token"] !== TOKEN) {
    res.writeHead(401);
    return res.end("token");
  }

  if (req.method === "GET" && url === "/state") {
    if (DRY) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end("{}");
    }
    try {
      const buf = await ask("state");
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      return res.end(buf.length ? buf : "{}");
    } catch {
      res.writeHead(503);
      return res.end();
    }
  }

  if (req.method === "GET" && url === "/screen") {
    if (DRY) {
      res.writeHead(204);
      return res.end();
    }
    const divisor = Math.min(6, Math.max(1, Number(new URLSearchParams(query).get("d")) || 2));
    try {
      const buf = await ask(`shot ${divisor}`);
      res.writeHead(200, { "content-type": "image/jpeg", "cache-control": "no-store" });
      return res.end(buf);
    } catch {
      res.writeHead(503);
      return res.end();
    }
  }

  if (req.method === "POST" && url === "/do") {
    let body = "";
    req.on("data", (c) => {
      body += c;
      if (body.length > 8000) req.destroy();
    });
    req.on("end", () => {
      res.writeHead(body.split("\n").every(fire) ? 204 : 400);
      res.end();
    });
    return;
  }

  res.writeHead(404);
  res.end();
}

const lanIp = Object.values(os.networkInterfaces())
  .flat()
  .filter((i) => i.family === "IPv4" && !i.internal)
  .map((i) => i.address)[0];

// Certificado propio, generado una sola vez en el store del usuario (sin admin).
// El telefono va a avisar que no lo conoce: hay que aceptarlo a mano una vez.
function tls() {
  const pfx = path.join(__dirname, "cert.pfx");
  if (!fs.existsSync(pfx)) {
    execFileSync("powershell", [
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
      `$c = New-SelfSignedCertificate -DnsName '${lanIp || "127.0.0.1"}','localhost' -CertStoreLocation Cert:\\CurrentUser\\My -NotAfter (Get-Date).AddYears(5);` +
        `Export-PfxCertificate -Cert $c -FilePath '${pfx}' -Password (ConvertTo-SecureString 'telemando' -Force -AsPlainText) | Out-Null`,
    ]);
  }
  return { pfx: fs.readFileSync(pfx), passphrase: "telemando" };
}

const server = (USE_HTTPS ? https.createServer(tls(), handle) : http.createServer(handle)).listen(PORT, () => {
  if (DRY) return;
  const link = `${USE_HTTPS ? "https" : "http"}://${lanIp || "127.0.0.1"}:${PORT}/?t=${TOKEN}`;
  console.log(`\n  Telemando escuchando. Abrí esto en el teléfono:\n\n  ${link}\n`);
  // Tipear un token de 16 caracteres en un telefono es una tortura: el link
  // queda copiado y se manda por donde sea mas comodo.
  fire("clip " + Buffer.from(link, "utf8").toString("base64"));
  console.log(`  Ya está copiado en el portapapeles. Mandátelo por WhatsApp o Telegram\n  y tocalo desde el teléfono.`);
  console.log(`  Sigue valiendo después de reiniciar: el token vive en token.txt\n`);
});

module.exports = { server, TOKEN };
