// node test.js — token, filtro de órdenes y la cáscara pública.
// Corre con TELEMANDO_DRY=1: no toca el escritorio.
process.env.TELEMANDO_DRY = "1";
process.env.TELEMANDO_TOKEN = "t0ken";
process.env.PORT = "7071";
const assert = require("assert");
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

  // La cáscara se sirve sin token; el estado y las capturas, no.
  for (const p of ["/", "/manifest.webmanifest", "/sw.js", "/icon-192.png", "/icon-512.png", "/icon.svg"]) {
    assert.equal(await get(p), 200, p + " tiene que servirse sin token");
  }
  assert.equal(await get("/no-existe"), 401);

  console.log("ok");
  server.close();
})();
