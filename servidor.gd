extends Node

# =========================
# SERVIDOR DE SALAS — ALL IN MOM
# =========================
# Roda no Render.com (veja GUIA_RENDER.md), na Oracle ou em qualquer PC:
#   godot --headless --path servidor_salas
# Opções: --porta=9080  (ou as variáveis de ambiente PORT / PORTA)
#
# O que ele faz (e só isso):
#   - cria salas com código de 6 letras/números (ex.: K7P2QX);
#   - "apresenta" os jogadores ao dono da sala (repassa as mensagens do
#     WebRTC: offer / answer / candidate);
#   - tranca a sala quando a partida começa e bloqueia quem foi expulso.
# O jogo em si NÃO passa por aqui: depois de apresentados, os jogadores
# conversam direto com o dono da sala (WebRTC). Por isso ele é leve e cabe
# folgado na máquina grátis.

const PORTA_PADRAO := 9080
const MAX_JOGADORES := 8
const LETRAS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # sem O/0 e I/1
const TAMANHO_MAXIMO_MSG := 64 * 1024
const TEMPO_SEM_RESPOSTA := 90.0   # segundos sem mensagem = desconectado

const TEMPO_HANDSHAKE := 10.0      # segundos para mandar o pedido inicial
const GUID_WEBSOCKET := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# O WebSocket é feito "na mão" (em vez do WebSocketPeer do Godot) para que o
# servidor também responda a visitas comuns por HTTP. O Render (e outros
# serviços) ficam visitando o endereço para ver se o servidor está vivo; sem
# isso essas visitas davam erro e o serviço parecia quebrado.

var _tcp := TCPServer.new()
var _clientes := {}   # cid -> { tcp, buf, fase ("http"/"ws"/"fim"), fragmento, sala, id, ip, visto }
var _salas := {}      # codigo -> { dono: cid, membros: {id: cid}, trancada, expulsos: {ip: true} }
var _proximo_cid := 1


func _ready() -> void:
	var porta := PORTA_PADRAO
	# O Render (e outros serviços na nuvem) dizem a porta pela variável PORT.
	if OS.has_environment("PORT"):
		porta = int(OS.get_environment("PORT"))
	if OS.has_environment("PORTA"):
		porta = int(OS.get_environment("PORTA"))
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--porta="):
			porta = int(arg.substr(8))
	var erro := _tcp.listen(porta)
	if erro != OK:
		printerr("Não foi possível abrir a porta %d (%s)" % [porta, error_string(erro)])
		get_tree().quit(1)
		return
	print("Servidor de salas ligado na porta %d" % porta)


func _process(_delta: float) -> void:
	while _tcp.is_connection_available():
		var conexao := _tcp.take_connection()
		_clientes[_proximo_cid] = {
			"tcp": conexao, "buf": PackedByteArray(), "fase": "http", "fragmento": PackedByteArray(),
			"sala": "", "id": 0, "ip": conexao.get_connected_host(), "visto": _agora(),
		}
		_proximo_cid += 1

	for cid in _clientes.keys():
		if not _clientes.has(cid):
			continue
		var c: Dictionary = _clientes[cid]
		var tcp: StreamPeerTCP = c.tcp
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED or c.fase == "fim":
			tcp.disconnect_from_host()
			_remover(cid)
			continue
		var disponivel := tcp.get_available_bytes()
		if disponivel > 0:
			var lido := tcp.get_partial_data(disponivel)
			if lido[0] == OK:
				c.buf.append_array(lido[1])
		if c.fase == "http":
			_ler_pedido_http(cid, c)
		if c.fase == "ws":
			_ler_quadros(cid, c)
			if _agora() - c.visto > TEMPO_SEM_RESPOSTA:
				_fechar(cid)


func _agora() -> float:
	return Time.get_ticks_msec() / 1000.0


# --- Primeira mensagem: pedido HTTP (visita comum ou pedido de WebSocket) ---

func _ler_pedido_http(cid: int, c: Dictionary) -> void:
	var buf: PackedByteArray = c.buf
	var texto: String = buf.get_string_from_ascii()
	var fim: int = texto.find("\r\n\r\n")
	if fim == -1:
		if buf.size() > 8192 or _agora() - c.visto > TEMPO_HANDSHAKE:
			c.fase = "fim"
		return
	var cabecalhos := {}
	var linhas: PackedStringArray = texto.substr(0, fim).split("\r\n")
	for i in range(1, linhas.size()):
		var dois_pontos: int = linhas[i].find(":")
		if dois_pontos > 0:
			cabecalhos[linhas[i].substr(0, dois_pontos).strip_edges().to_lower()] = linhas[i].substr(dois_pontos + 1).strip_edges()
	c.buf = buf.slice(fim + 4)

	var chave := str(cabecalhos.get("sec-websocket-key", ""))
	if str(cabecalhos.get("upgrade", "")).to_lower() != "websocket" or chave == "":
		# Visita comum (verificação de saúde, navegador...): responde "ok".
		var corpo := "ALL IN MOM - servidor de salas funcionando.\n"
		var resposta := "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [corpo.to_utf8_buffer().size(), corpo]
		c.tcp.put_data(resposta.to_utf8_buffer())
		c.fase = "fim"
		return

	var sha := HashingContext.new()
	sha.start(HashingContext.HASH_SHA1)
	sha.update((chave + GUID_WEBSOCKET).to_utf8_buffer())
	var aceite := Marshalls.raw_to_base64(sha.finish())
	var resposta := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % aceite
	c.tcp.put_data(resposta.to_utf8_buffer())
	c.fase = "ws"
	c.visto = _agora()


# --- Quadros (frames) do WebSocket ---

func _ler_quadros(cid: int, c: Dictionary) -> void:
	while _clientes.has(cid) and c.fase == "ws":
		var b: PackedByteArray = c.buf
		if b.size() < 2:
			return
		var fin := (b[0] & 0x80) != 0
		var op := b[0] & 0x0F
		var mascarado := (b[1] & 0x80) != 0
		var tamanho := b[1] & 0x7F
		var pos := 2
		if tamanho == 126:
			if b.size() < 4:
				return
			tamanho = (b[2] << 8) | b[3]
			pos = 4
		elif tamanho == 127:
			if b.size() < 10:
				return
			tamanho = 0
			for i in range(2, 10):
				tamanho = (tamanho << 8) | b[i]
			pos = 10
		if tamanho > TAMANHO_MAXIMO_MSG:
			c.fase = "fim"
			return
		var mascara := PackedByteArray()
		if mascarado:
			if b.size() < pos + 4:
				return
			mascara = b.slice(pos, pos + 4)
			pos += 4
		if b.size() < pos + tamanho:
			return
		var dados := b.slice(pos, pos + tamanho)
		if mascarado:
			for i in dados.size():
				dados[i] = dados[i] ^ mascara[i % 4]
		c.buf = b.slice(pos + tamanho)
		c.visto = _agora()

		match op:
			0x0, 0x1, 0x2:   # continuação / texto / binário
				c.fragmento.append_array(dados)
				if c.fragmento.size() > TAMANHO_MAXIMO_MSG:
					c.fase = "fim"
					return
				if fin:
					var msg = JSON.parse_string(c.fragmento.get_string_from_utf8())
					c.fragmento = PackedByteArray()
					if msg is Dictionary:
						_tratar(cid, msg)
			0x8:   # fechar
				_mandar_quadro(c, 0x8, PackedByteArray())
				c.fase = "fim"
			0x9:   # ping -> pong
				_mandar_quadro(c, 0xA, dados)


func _mandar_quadro(c: Dictionary, op: int, dados: PackedByteArray) -> void:
	var quadro := PackedByteArray([0x80 | op])
	var n := dados.size()
	if n < 126:
		quadro.append(n)
	elif n < 65536:
		quadro.append_array([126, (n >> 8) & 0xFF, n & 0xFF])
	else:
		quadro.append(127)
		for i in range(7, -1, -1):
			quadro.append((n >> (8 * i)) & 0xFF)
	quadro.append_array(dados)
	c.tcp.put_data(quadro)


func _enviar(cid: int, msg: Dictionary) -> void:
	var c = _clientes.get(cid)
	if c and c.fase == "ws":
		_mandar_quadro(c, 0x1, JSON.stringify(msg).to_utf8_buffer())


func _fechar(cid: int) -> void:
	var c = _clientes.get(cid)
	if c and c.fase == "ws":
		_mandar_quadro(c, 0x8, PackedByteArray())
	if c:
		c.fase = "fim"

func _gerar_codigo() -> String:
	while true:
		var codigo := ""
		for i in 6:
			codigo += LETRAS[randi() % LETRAS.length()]
		if not _salas.has(codigo):
			return codigo
	return ""


func _tratar(cid: int, msg: Dictionary) -> void:
	var c: Dictionary = _clientes[cid]
	match str(msg.get("tipo", "")):
		"criar":
			if c.sala != "":
				return
			var codigo := _gerar_codigo()
			_salas[codigo] = { "dono": cid, "membros": { 1: cid }, "trancada": false, "expulsos": {} }
			c.sala = codigo
			c.id = 1
			_enviar(cid, { "tipo": "sala", "codigo": codigo, "id": 1 })
			print("Sala %s criada (%d salas abertas)" % [codigo, _salas.size()])

		"entrar":
			if c.sala != "":
				return
			var codigo := str(msg.get("codigo", "")).strip_edges().to_upper()
			var sala = _salas.get(codigo)
			if sala == null:
				_enviar(cid, { "tipo": "erro", "msg": "Sala %s não encontrada. Confira o código." % codigo })
			elif sala.expulsos.has(c.ip):
				_enviar(cid, { "tipo": "erro", "msg": "Você foi expulso desta sala." })
			elif sala.trancada:
				_enviar(cid, { "tipo": "erro", "msg": "A partida desta sala já começou." })
			elif sala.membros.size() >= MAX_JOGADORES:
				_enviar(cid, { "tipo": "erro", "msg": "A sala está cheia (máximo %d)." % MAX_JOGADORES })
			else:
				var id := 0
				while id < 2 or sala.membros.has(id):
					id = randi_range(2, 2147483646)
				sala.membros[id] = cid
				c.sala = codigo
				c.id = id
				_enviar(cid, { "tipo": "sala", "codigo": codigo, "id": id })
				# Os dois lados criam a ligação direta; o dono faz a "oferta".
				_enviar(sala.dono, { "tipo": "novo", "id": id })
				_enviar(cid, { "tipo": "novo", "id": 1 })

		"offer", "answer", "candidate":
			var sala = _salas.get(c.sala)
			if sala == null:
				return
			var para := int(msg.get("para", 0))
			if not sala.membros.has(para):
				return
			# Só repassa entre o dono e os outros (o jogo é em estrela).
			if c.id != 1 and para != 1:
				return
			var repasse := msg.duplicate()
			repasse.erase("para")
			repasse["de"] = c.id
			_enviar(sala.membros[para], repasse)

		"trancar":
			var sala = _salas.get(c.sala)
			if sala and c.id == 1:
				sala.trancada = bool(msg.get("valor", true))

		"expulsar":
			var sala = _salas.get(c.sala)
			if sala and c.id == 1:
				var alvo := int(msg.get("id", 0))
				if sala.membros.has(alvo) and alvo != 1:
					var cid_alvo: int = sala.membros[alvo]
					# Atrás do Caddy/Render todo mundo aparece com o IP interno do
					# proxy; aí o bloqueio fica por conta do jogo do dono (lista
					# de expulsos), senão bloquearia gente inocente.
					var ip: String = _clientes[cid_alvo].ip
					if not _ip_interno(ip):
						sala.expulsos[ip] = true
					_fechar(cid_alvo)

		"ping":
			pass


static func _ip_interno(ip: String) -> bool:
	ip = ip.trim_prefix("::ffff:")
	if ip == "::1" or ip.begins_with("127.") or ip.begins_with("10.") or ip.begins_with("192.168.") or ip.begins_with("fc") or ip.begins_with("fd"):
		return true
	if ip.begins_with("172."):
		var segundo := int(ip.get_slice(".", 1))
		return segundo >= 16 and segundo <= 31
	return false


func _remover(cid: int) -> void:
	var c: Dictionary = _clientes[cid]
	_clientes.erase(cid)
	var sala = _salas.get(c.sala)
	if sala == null:
		return
	if c.id == 1:
		# O dono saiu do servidor de salas: a sala some (ninguém mais entra).
		for id in sala.membros:
			if id != 1:
				_enviar(sala.membros[id], { "tipo": "fechada" })
		_salas.erase(c.sala)
		print("Sala %s fechada (%d salas abertas)" % [c.sala, _salas.size()])
	else:
		sala.membros.erase(c.id)
		_enviar(sala.dono, { "tipo": "saiu", "id": c.id })
