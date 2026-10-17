"""Renderiza o ciclo de vida de incidentes como PNG para embutir no relatório.

O enunciado da Fase 5 exige o desenho do ciclo na seção ITSM/AIOps do relatório.
O diagrama equivalente existe em docs/ITSM-AIOPS.md em Mermaid, que o GitHub
renderiza mas o gerador de PDF não interpreta. Desenhar localmente com Pillow
evita depender de serviço externo de renderização e mantém a identidade visual
do documento.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

RAIZ = Path(__file__).resolve().parents[1]
DESTINO = RAIZ / "docs" / "evidencias" / "14-ciclo-incidente.png"

ESCALA = 2  # desenha no dobro e reduz no final, para suavizar as bordas
LARGURA, ALTURA = 1180 * ESCALA, 430 * ESCALA

AZUL_ESCURO = "#12355b"
AZUL = "#176b87"
CINZA_TEXTO = "#172033"
CINZA_BORDA = "#b7c4cf"
FUNDO_CAIXA = "#eef4f7"
BRANCO = "#ffffff"

ETAPAS = [
    ("Observabilidade", "Prometheus, Grafana\ne New Relic"),
    ("Detecção", "regra de burn rate\nentra em disparo"),
    ("Evento enriquecido", "serviço, severidade,\nSLO e dashboard"),
    ("Registro do incidente", "PagerDuty, Discord\ne GitHub"),
    ("Triagem e correlação", "labels iguais\nevitam duplicidade"),
    ("Mitigação", "self-healing e\nreconciliação do Argo CD"),
    ("Validação do SLI", "taxa de erro volta\nao objetivo"),
    ("Post-mortem", "linha do tempo,\nMTTD e MTTR"),
]

CAIXA_L, CAIXA_A = 250 * ESCALA, 96 * ESCALA
VAO = 38 * ESCALA
MARGEM_X = 40 * ESCALA
Y_LINHA_1 = 86 * ESCALA
Y_LINHA_2 = 250 * ESCALA


def fonte(tamanho, negrito=False):
    for nome in (("seguisb.ttf", "arialbd.ttf") if negrito else ("segoeui.ttf", "arial.ttf")):
        try:
            return ImageFont.truetype(nome, tamanho * ESCALA)
        except OSError:
            continue
    return ImageFont.load_default()


def centraliza(desenho, texto, fonte_usada, x_centro, y_topo, cor, espacamento=0):
    for indice, linha in enumerate(texto.split("\n")):
        caixa = desenho.textbbox((0, 0), linha, font=fonte_usada)
        desenho.text(
            (x_centro - (caixa[2] - caixa[0]) / 2, y_topo + indice * espacamento),
            linha,
            font=fonte_usada,
            fill=cor,
        )


def seta_horizontal(desenho, x_inicio, y, x_fim):
    desenho.line([(x_inicio, y), (x_fim - 9 * ESCALA, y)], fill=AZUL, width=3 * ESCALA)
    desenho.polygon(
        [(x_fim, y), (x_fim - 10 * ESCALA, y - 6 * ESCALA), (x_fim - 10 * ESCALA, y + 6 * ESCALA)],
        fill=AZUL,
    )


imagem = Image.new("RGB", (LARGURA, ALTURA), BRANCO)
desenho = ImageDraw.Draw(imagem)

f_titulo = fonte(16, negrito=True)
f_rotulo = fonte(11, negrito=True)
f_detalhe = fonte(9)
f_numero = fonte(9, negrito=True)

centraliza(desenho, "Ciclo de vida de um incidente na SolidaryTech", f_titulo, LARGURA / 2, 18 * ESCALA, AZUL_ESCURO)

for indice_linha, (etapas, y_topo) in enumerate(((ETAPAS[:4], Y_LINHA_1), (ETAPAS[4:], Y_LINHA_2))):
    for posicao, (rotulo, detalhe) in enumerate(etapas):
        x = MARGEM_X + posicao * (CAIXA_L + VAO)
        desenho.rounded_rectangle(
            [x, y_topo, x + CAIXA_L, y_topo + CAIXA_A],
            radius=10 * ESCALA,
            fill=FUNDO_CAIXA,
            outline=CINZA_BORDA,
            width=2 * ESCALA,
        )
        desenho.ellipse(
            [x + 10 * ESCALA, y_topo + 10 * ESCALA, x + 30 * ESCALA, y_topo + 30 * ESCALA],
            fill=AZUL,
        )
        centraliza(desenho, str(indice_linha * 4 + posicao + 1), f_numero, x + 20 * ESCALA, y_topo + 14 * ESCALA, BRANCO)
        centraliza(desenho, rotulo, f_rotulo, x + CAIXA_L / 2, y_topo + 38 * ESCALA, AZUL_ESCURO)
        centraliza(desenho, detalhe, f_detalhe, x + CAIXA_L / 2, y_topo + 60 * ESCALA, CINZA_TEXTO, 13 * ESCALA)

        if posicao < 3:
            seta_horizontal(desenho, x + CAIXA_L + 6 * ESCALA, y_topo + CAIXA_A / 2, x + CAIXA_L + VAO - 6 * ESCALA)

# Conector entre as duas linhas: desce sob a quarta caixa e retorna à primeira da linha de baixo.
x_fim_linha = MARGEM_X + 3 * (CAIXA_L + VAO) + CAIXA_L / 2
x_inicio_linha = MARGEM_X + CAIXA_L / 2
y_meio = 220 * ESCALA
desenho.line([(x_fim_linha, Y_LINHA_1 + CAIXA_A), (x_fim_linha, y_meio)], fill=AZUL, width=3 * ESCALA)
desenho.line([(x_fim_linha, y_meio), (x_inicio_linha, y_meio)], fill=AZUL, width=3 * ESCALA)
desenho.line([(x_inicio_linha, y_meio), (x_inicio_linha, Y_LINHA_2 - 11 * ESCALA)], fill=AZUL, width=3 * ESCALA)
desenho.polygon(
    [
        (x_inicio_linha, Y_LINHA_2),
        (x_inicio_linha - 6 * ESCALA, Y_LINHA_2 - 11 * ESCALA),
        (x_inicio_linha + 6 * ESCALA, Y_LINHA_2 - 11 * ESCALA),
    ],
    fill=AZUL,
)

RODAPE = (
    "P1 reconhecido em até 10 minutos, mitigação alvo em 60 minutos e post-mortem em 2 dias úteis.    "
    "MTTD e MTTR derivam dos carimbos de sintoma, alerta e restauração."
)
centraliza(desenho, RODAPE, f_detalhe, LARGURA / 2, 390 * ESCALA, "#667788")

DESTINO.parent.mkdir(parents=True, exist_ok=True)
imagem.resize((LARGURA // ESCALA, ALTURA // ESCALA), Image.LANCZOS).save(DESTINO, "PNG")
print(f"Diagrama gerado: {DESTINO}")
