// node test.js — token, filtro de órdenes y la cáscara pública.
// Corre con TELEMANDO_DRY=1: no toca el escritorio.
process.env.TELEMANDO_DRY = "1";
process.env.TELEMANDO_TOKEN = "t0ken";
process.env.PORT = "7071";
const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
process.env.TELEMANDO_BOTONES = path.join(os.tmpdir(), `telemando-botones-${process.pid}.json`);
const { server } = require("./server.js");

const base = "http://127.0.0.1:7071";
const post = (body, token = "t0ken") =>
  fetch(base + "/do", { method: "POST", headers: { "x-token": token }, body }).then((r) => r.status);
const get = (p, token) =>
  fetch(base + p, { headers: token ? { "x-token": token } : {} }).then((r) => r.status);

(async () => {
  // Sin token no se controla nada.
  assert.equal(await post("click", "mal"), 401);
  assert.equal(await get("/state"), 401, "el estado también pide token");
  assert.equal(await get("/screen"), 401, "la captura también pide token");

  // Órdenes válidas.
  assert.equal(await post("click"), 204);
  assert.equal(await post("move 3,-4\nvol 40\nclick"), 204, "varias órdenes por request");
  assert.equal(await post("moveto 0.5,0.25"), 204);
  assert.equal(await post("output {0.0.0.00000000}.{abc}"), 204);
  assert.equal(await post("sys lock"), 204);
  assert.equal(await post("clip aG9sYQ=="), 204);
  assert.equal(await post("open https://example.com"), 204);

  // Lo que no está en la lista no baja al escritorio.
  assert.equal(await post("Remove-Item C:\\ -Recurse"), 400);
  assert.equal(await post("iex algo"), 400);

  // "open" es el único con texto libre: solo http(s), nada de rutas ni de
  // encadenar otro comando.
  assert.equal(await post("open file:///C:/Windows/System32/cmd.exe"), 400);
  assert.equal(await post("open calc.exe"), 400);
  assert.equal(await post("open https://a.com && calc"), 400);
  assert.equal(await post('open https://a.com"'), 400);

  // Brillo por pantalla: id de pantalla y porcentaje, nada más.
  assert.equal(await post("bright ddc0 70"), 204);
  assert.equal(await post("bright wmi 40"), 204);
  assert.equal(await post("bright 50"), 400, "el formato viejo sin pantalla ya no va");
  assert.equal(await post("bright ddc0 70; calc"), 400);

  // Apuntar en la pantalla que se está mirando: una, otra o todas juntas.
  assert.equal(await post("moveto 0.5,0.25 1"), 204);
  assert.equal(await post("moveto 0.5,0.25 all"), 204);
  assert.equal(await post("moveto 1,0"), 204);
  assert.equal(await post("moveto 0.5,0.25 ; calc"), 400);
  assert.equal(await post("moveto 5,5"), 400, "fuera de 0..1 no");

  // Modo juego: teclas que quedan apretadas, solo con un número.
  assert.equal(await post("kd 38\nkd 88\nku 38\nkall"), 204);
  assert.equal(await post("kd abc"), 400);
  assert.equal(await post("kall ya"), 400);

  // launch: el AppID en base64, y nada más en la línea.
  const appId = Buffer.from("AppleInc.AppleMusicWin_nzyj5cx40ttqa!App").toString("base64");
  assert.equal(await post("launch " + appId), 204);
  assert.equal(await post("launch calc.exe && rm"), 400);

  // Las teclas de abrir apps se guardan en la compu, validadas.
  const json = (p, body) =>
    fetch(base + p, { method: "POST", headers: { "x-token": "t0ken" }, body: JSON.stringify(body) }).then((r) => r.status);
  const leer = () => fetch(base + "/botones", { headers: { "x-token": "t0ken" } }).then((r) => r.json());
  assert.equal(await get("/botones"), 401, "las teclas guardadas piden token");
  assert.equal((await leer())[1].cmd, "app spotify", "sin archivo, las de fábrica");
  const mias = [
    { label: "Apple Music", ico: "♫", cmd: "launch " + appId },
    { label: "Archivos", ico: "▤", cmd: "app explorer" },
  ];
  assert.equal(await json("/botones", mias), 204);
  assert.deepEqual(await leer(), mias);
  assert.equal(await json("/botones", [{ label: "x", ico: "", cmd: "open https://a.com" }]), 400, "solo app y launch");
  assert.equal(await json("/botones", [{ label: "x", ico: "", cmd: "app cmd.exe" }]), 400, "app solo de la lista fija");
  assert.equal(await json("/botones", [{ label: "", ico: "", cmd: "app calc" }]), 400, "sin nombre no");
  assert.equal(await json("/botones", Array(19).fill(mias[1])), 400, "18 como mucho");
  assert.equal(await json("/botones", { no: "es una lista" }), 400);
  assert.deepEqual(await leer(), mias, "lo rechazado no pisa lo guardado");
  fs.rmSync(process.env.TELEMANDO_BOTONES, { force: true });

  // La cáscara se sirve sin token; el estado y las capturas, no.
  for (const p of ["/", "/manifest.webmanifest", "/sw.js", "/icon-192.png", "/icon-512.png", "/icon.svg"]) {
    assert.equal(await get(p), 200, p + " tiene que servirse sin token");
  }
  assert.equal(await get("/no-existe"), 401);

  console.log("ok");
  server.close();
})();
