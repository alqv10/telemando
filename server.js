const http = require("http");
const https = require("https");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");
const crypto = require("crypto");
const { spawn, execFileSync } = require("child_process");

// Si algo revienta, que quede escrito: corriendo minimizado o con
// autostart nadie ve la consola, y el servidor simplemente desaparecía sin
// dejar rastro. Se anota y se sigue: un control remoto que se cae solo es
// peor que uno que se salteó una orden.
const errorLog = path.join(__dirname, "telemando-error.log");
function anotarError(tipo, err) {
  const linea = `[${new Date().toISOString()}] ${tipo}: ${(err && err.stack) || err}\n`;
  console.error(linea);
  try { fs.appendFileSync(errorLog, linea); } catch {}
}
process.on("uncaughtException", (e) => anotarError("uncaughtException", e));
process.on("unhandledRejection", (e) => anotarError("unhandledRejection", e));

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
// El motor puede morirse: lo mata el usuario, se cae PowerShell. Antes eso se
// llevaba puesto al servidor — escribirle a un stdin cerrado tira EPIPE y nadie
// lo atrapaba. Ahora se levanta solo y el teléfono ni se entera.
let helper = null;

function arrancarHelper() {
  if (DRY) return;
  helper = spawn(
    "powershell",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(__dirname, "helper.ps1")],
    { stdio: ["pipe", "pipe", "inherit"] }
  );

  // Las respuestas vuelven por stdout: "res <id> <base64>".
  readline.createInterface({ input: helper.stdout }).on("line", (line) => {
    const [tag, id, payload] = line.split(" ");
    if (tag !== "res") return;
    const esperando = pending.get(id);
    if (!esperando) return;
    pending.delete(id);
    esperando(Buffer.from(payload || "", "base64"));
  });

  helper.stdin.on("error", () => {});          // el cierre se maneja en exit
  helper.on("exit", (code) => {
    helper = null;
    pending.clear();                           // nadie va a contestar esas
    console.error(`  El motor de PowerShell se cerró (código ${code}); lo levanto de nuevo.`);
    setTimeout(arrancarHelper, 1000);
  });
}

const ACTIONS = new Set([
  "move", "moveto", "click", "dblclick", "rclick", "mclick", "down", "up",
  "scroll", "hscroll", "vk", "keys", "vol", "mute", "output", "bright",
  "app", "open", "focus", "closewin", "clip", "sys", "launch", "kd", "ku", "kall",
]);

// Los verbos nuevos traen la forma de su argumento atada: lo que no calza no
// llega ni al helper, que de todos modos vuelve a revisar.
const FORMA = {
  bright: /^bright (wmi|ddc\d{1,2}) \d{1,3}$/,
  moveto: /^moveto [01](\.\d{1,6})?,[01](\.\d{1,6})?( (\d|all|p))?$/,
  launch: /^launch [A-Za-z0-9+/]{1,1000}={0,2}$/,    // el AppID va en base64
  kd: /^kd \d{1,3}$/,
  ku: /^ku \d{1,3}$/,
  kall: /^kall$/,
};

// Las teclas de "abrir en la compu" son de cada uno: Apple Music en vez de
// Spotify, el juego de turno en vez de la calculadora. Viven en la compu y no
// en el telefono, asi el navegador y la app de Safari ven las mismas.
const botonesFile = process.env.TELEMANDO_BOTONES || path.join(__dirname, "botones.json");
const APPS_FIJAS = ["explorer", "calc", "notepad", "taskmgr", "settings", "spotify", "terminal"];
const BOTONES_DE_FABRICA = [
  { label: "Archivos", ico: "▤", cmd: "app explorer" },
  { label: "Spotify", ico: "♫", cmd: "app spotify" },
  { label: "Ajustes", ico: "⚙", cmd: "app settings" },
  { label: "Calculadora", ico: "#", cmd: "app calc" },
  { label: "Bloc", ico: "✎", cmd: "app notepad" },
  { label: "Procesos", ico: "▦", cmd: "app taskmgr" },
  { label: "Terminal", ico: "▶_", cmd: "app terminal" },
];

function botonValido(b) {
  return (
    b && typeof b === "object" &&
    typeof b.label === "string" && b.label.trim().length >= 1 && b.label.length <= 30 &&
    typeof b.ico === "string" && b.ico.length <= 4 &&
    typeof b.cmd === "string" &&
    ((b.cmd.startsWith("app ") && APPS_FIJAS.includes(b.cmd.slice(4))) || FORMA.launch.test(b.cmd))
  );
}

function leerBotones() {
  try {
    const b = JSON.parse(fs.readFileSync(botonesFile, "utf8"));
    if (Array.isArray(b) && b.every(botonValido)) return b;
  } catch {}
  return BOTONES_DE_FABRICA;
}

let nextId = 1;
const pending = new Map();

arrancarHelper();

function fire(line) {
  const verb = line.split(" ", 1)[0];
  if (!ACTIONS.has(verb) || /[\r\n]/.test(line)) return false;
  if (FORMA[verb] && !FORMA[verb].test(line)) return false;
  // "open" es el unico que recibe texto libre: solo http(s), nada de rutas
  // ni protocolos raros que Start-Process ejecutaria.
  if (verb === "open" && !/^open https?:\/\/[^\s"'|&;]+$/.test(line)) return false;
  if (helper) helper.stdin.write(`- ${line}\n`);   // si se está levantando, se pierde la orden, no el servidor
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
    if (!helper) {
      clearTimeout(timer);
      return reject(new Error("el motor todavía no está"));
    }
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
  if ((req.method === "GET" || req.method === "HEAD") && asset) {
    try {
      const body = fs.readFileSync(path.join(__dirname, asset[0]));
      // La pagina va sin guardar: una app agregada a la pantalla principal se
      // queda con la copia vieja y despues no entiende por que no anda.
      const guardar = url === "/" ? "no-store" : "no-cache";
      res.writeHead(200, { "content-type": asset[1], "cache-control": guardar });
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
    const q = new URLSearchParams(query);
    const divisor = Math.min(6, Math.max(1, Math.round(Number(q.get("d"))) || 2));
    // calidad del JPEG: con zoom se ven los bloques de la compresión
    const calidad = Math.min(90, Math.max(30, Math.round(Number(q.get("q"))) || 55));
    // qué pantalla: "0", "1"… de izquierda a derecha, "all" todas juntas
    const cual = /^(\d|all)$/.test(q.get("s") || "") ? q.get("s") : "p";
    try {
      const buf = await ask(`shot ${divisor} ${calidad} ${cual}`);
      res.writeHead(200, { "content-type": "image/jpeg", "cache-control": "no-store" });
      return res.end(buf);
    } catch {
      res.writeHead(503);
      return res.end();
    }
  }

  // Lo que hay instalado, para elegir con qué reemplazar una tecla.
  if (req.method === "GET" && url === "/apps") {
    if (DRY) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end("[]");
    }
    try {
      const buf = await ask("startapps");
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      return res.end(buf.length ? buf : "[]");
    } catch {
      res.writeHead(503);
      return res.end();
    }
  }

  if (req.method === "GET" && url === "/botones") {
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    return res.end(JSON.stringify(leerBotones()));
  }

  if (req.method === "POST" && url === "/botones") {
    let body = "";
    req.on("data", (c) => {
      body += c;
      if (body.length > 20000) req.destroy();
    });
    req.on("end", () => {
      let b;
      try { b = JSON.parse(body); } catch {}
      if (!Array.isArray(b) || b.length > 18 || !b.every(botonValido)) {
        res.writeHead(400);
        return res.end();
      }
      // Solo los campos conocidos: nada extra se cuela al archivo.
      const limpio = b.map(({ label, ico, cmd }) => ({ label: label.trim(), ico, cmd }));
      fs.writeFileSync(botonesFile, JSON.stringify(limpio, null, 2));
      res.writeHead(204);
      res.end();
    });
    return;
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

// No poder escuchar sí es para irse: con el manejador de arriba el proceso
// quedaría vivo sin atender a nadie.
server.on("error", (e) => {
  anotarError("server", e);
  if (e.code === "EADDRINUSE") console.error(`  El puerto ${PORT} ya está en uso: ¿telemando ya está corriendo?`);
  process.exit(1);
});

module.exports = { server, TOKEN };
