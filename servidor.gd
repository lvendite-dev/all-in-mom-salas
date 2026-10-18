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

var _tcp := TCPServer.new()
var _clientes := {}   # cid -> { ws, sala, id, ip, visto }
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
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = TAMANHO_MAXIMO_MSG
		if ws.accept_stream(conexao) == OK:
			_clientes[_proximo_cid] = { "ws": ws, "sala": "", "id": 0, "ip": conexao.get_connected_host(), "visto": _agora() }
			_proximo_cid += 1

	for cid in _clientes.keys():
		var c: Dictionary = _clientes[cid]
		var ws: WebSocketPeer = c.ws
		ws.poll()
		var estado := ws.get_ready_state()
		if estado == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				c.visto = _agora()
				var msg = JSON.parse_string(ws.get_packet().get_string_from_utf8())
				if msg is Dictionary:
					_tratar(cid, msg)
			if _agora() - c.visto > TEMPO_SEM_RESPOSTA:
				ws.close()
		elif estado == WebSocketPeer.STATE_CLOSED:
			_remover(cid)


func _agora() -> float:
	return Time.get_ticks_msec() / 1000.0


func _enviar(cid: int, msg: Dictionary) -> void:
	var c = _clientes.get(cid)
	if c and c.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		c.ws.send_text(JSON.stringify(msg))


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
					_clientes[cid_alvo].ws.close()

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
