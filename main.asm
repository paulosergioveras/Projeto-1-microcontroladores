; -------------------------------------------------------------
; VISAO GERAL
; -------------------------------------------------------------
; O programa controla o cruzamento da Av. Alvaro Otacilio com a
; R. Prof. Sandoval Arroxelas, que tem quatro semaforos:
;   S1 - esquerda (poste com setas -> e para baixo, acendem juntas)
;   S2 - superior, seta <-
;   S3 - superior, seta para baixo
;   S4 - inferior, seta para cima
;
; Depois da configuracao inicial o laco principal fica vazio, e
; quem faz todo o trabalho sao tres interrupcoes:
;
;   Timer1, uma vez por segundo, mantem duas contagens separadas:
;     a) a maquina de estados do cruzamento, com 10 estados e um
;        ciclo de 155 s, que a cada estado define as 12 lampadas
;        de uma vez;
;     b) o contador do S2, que guarda quantos segundos faltam para
;        o S2 mudar de cor. O S2 passa S2_VERMELHO s no vermelho,
;        S2_VERDE s no verde e S2_AMARELO s no amarelo, e e esse
;        numero que aparece nos displays.
;
;   Timer0, a cada 2 ms, faz a multiplexacao dos dois displays com
;   um unico pino (PC4) e um transistor NPN. Como a troca e rapida
;   demais para o olho, parece que os dois digitos ficam acesos:
;     PC4 = 1 -> o NPN conduz -> dezena acesa, unidade apagada
;     PC4 = 0 -> o NPN corta e o pino puxa o catodo da unidade a 0
;                -> unidade acesa, dezena apagada
;
;   A USART, pela interrupcao de registrador vazio (UDRE), manda a
;   mensagem de status dos quatro semaforos pela serial sem parar
;   o resto do programa.
;
; -------------------------------------------------------------
; PINAGEM
; -------------------------------------------------------------
; Cada semaforo ocupa tres bits seguidos, na ordem vermelho,
; amarelo, verde:
;   PB0 PB1 PB2 (pinos 8, 9, 10)  -> S1 vermelho, amarelo, verde
;   PB3 PB4 PB5 (pinos 11,12,13)  -> S4 vermelho, amarelo, verde
;   PD2 PD3 PD4 (pinos 2, 3, 4)   -> S2 vermelho, amarelo, verde
;   PD5 PD6 PD7 (pinos 5, 6, 7)   -> S3 vermelho, amarelo, verde
;   PC0..PC3   (A0..A3)           -> entradas A, B, C, D do CD4511
;   PC4        (A4)               -> 2,2 kOhm -> base do NPN (comum da dezena)
;                                 -> direto no comum da unidade
;   PD0 / PD1                     -> serial RX/TX (reservados)
;   PC5 (A5)                      -> livre
;
; Os segmentos usam resistores de 1 kOhm. A unidade descarrega
; pelo PC4, entao no "8" passam cerca de 7 x 2,5 mA = 18 mA, abaixo
; do limite do pino.
;
; -------------------------------------------------------------
; BASES DE TEMPO
; -------------------------------------------------------------
; Timer1 (16 bits): 16 MHz / 256 = 62.500 contagens por segundo.
;   Com TOP = OCR1A = 62.500 - 1 = 62.499, ele estoura a cada 1 s.
; Timer0 (8 bits): 16 MHz / 256 = 62.500 contagens por segundo.
;   Com OCR0A = 124, sao 125 contagens = 2 ms por estouro.
;==============================================================

; .include "m328Pdef.inc"      ; o Microchip Studio ja inclui o arquivo
                                ; do dispositivo escolhido no projeto

;==============================================================
; BLOCO 1 - TEMPOS DO S2 (o semaforo que aparece no display)
;--------------------------------------------------------------
; O S2 e o semaforo superior com a seta <-. Os tempos abaixo foram
; medidos na programacao do cruzamento:
;   vermelho: de 1m52s a 2m35s mais de 0s a 0m21s = 43 + 21 = 64 s
;   verde   : de 0m21s a 1m48s                     = 87 s
;   amarelo : de 1m48s a 1m52s                     =  4 s
; Ele e o primeiro a abrir depois do "todos vermelhos" e o que
; passa mais tempo no verde. As tres cores cabem em dois displays,
; que mostram no maximo 99.
;==============================================================
.equ S2_VERMELHO = 64           ; segundos que o S2 fica no vermelho (X)
.equ S2_VERDE    = 87           ; segundos que o S2 fica no verde (Z)
.equ S2_AMARELO  = 4            ; segundos que o S2 fica no amarelo (Y)
.equ CICLO       = 155          ; duracao do ciclo inteiro do cruzamento (2m35s)

;==============================================================
; BLOCO 2 - TEMPO INICIAL DO S2 (quanto falta para abrir ao ligar)
;--------------------------------------------------------------
; Ao ligar, o cruzamento entra no estado 0 (todos vermelhos), que
; no cronograma vai de 2m23s (143 s) ate os 21 s do ciclo seguinte.
; Nesse momento o S2 ja esta vermelho desde 1m52s (112 s), entao
; ainda faltam  S2_VERMELHO - (143 - 112) = 64 - 31 = 33 s. Esse
; valor coincide com a duracao do estado 0: o S2 abre quando ele
; termina.
;==============================================================
.equ S2_INICIAL  = S2_VERMELHO - (143 - 112)  ; segundos restantes do S2 ao ligar (= 33)

;==============================================================
; BLOCO 3 - CONFERENCIA DO MONTADOR (nao gera codigo)
;--------------------------------------------------------------
; As tres cores do S2 precisam somar exatamente um ciclo. Se nao
; somarem, o display sai de sincronia com os LEDs, e o montador
; interrompe a compilacao com a mensagem abaixo.
;==============================================================
.if (S2_VERMELHO + S2_VERDE + S2_AMARELO) != CICLO  ; a soma das cores difere do ciclo?
.error "Os tempos do S2 nao somam um ciclo do cruzamento"  ; para a compilacao avisando o erro
.endif                                              ; fim do teste condicional

;==============================================================
; BLOCO 4 - DEMAIS CONSTANTES
;==============================================================
.equ NUM_ESTADOS = 10           ; quantidade de estados da tabela do cruzamento
.equ APAGADO     = 0xFF         ; marca de dezena apagada (esconde o zero a esquerda)

;==============================================================
; BLOCO 5 - REGISTRADORES GLOBAIS
;--------------------------------------------------------------
; Dar um apelido a cada registrador com .def deixa o codigo mais
; legivel e evita usar o mesmo registrador para duas coisas por
; engano.
;==============================================================
.def cor_s2          = r18      ; cor atual do S2: 0 vermelho, 1 verde, 2 amarelo
.def contador_estado = r20      ; segundos que faltam no estado atual do cruzamento
.def estado_atual    = r21      ; indice do estado atual: 0 a 9 (linha da tabela)
.def dezena          = r22      ; digito da dezena do tempo do S2 (ou APAGADO)
.def unidade         = r23      ; digito da unidade do tempo do S2
.def tempo_s2        = r24      ; segundos que faltam para o S2 trocar de cor
.def digito_atual    = r25      ; fase da multiplexacao: 1 = dezena, 0 = unidade

; O par X (r26:r27) fica reservado como ponteiro de transmissao da
; serial: a ISR da UDRE o avanca a cada caractere. Nenhuma outra
; rotina usa X.

;==============================================================
; BLOCO 6 - BUFFER DA MENSAGEM SERIAL (na SRAM)
;--------------------------------------------------------------
; A mensagem de status dos quatro semaforos e montada aqui e sai
; pela ISR da UDRE sem parar o resto do programa. A linha mais
; longa possivel tem cerca de 90 bytes:
;   "Semaforo 1 - Vermelho; ... ; Semaforo 4 - Vermelho\r\n" + 0
;==============================================================
.dseg                           ; daqui em diante os enderecos sao da SRAM (dados)
.org SRAM_START                 ; comeca no inicio da RAM de dados
msg_buffer: .byte 100           ; reserva 100 bytes para a mensagem de status

;==============================================================
; BLOCO 7 - TABELA DE VETORES DE INTERRUPCAO
;--------------------------------------------------------------
; Cada vetor e so um "jmp" que o hardware executa quando o evento
; correspondente acontece. Declaramos apenas os vetores usados. O
; reset fica no endereco 0 e salta para a inicializacao; o resto
; do codigo comeca depois da tabela.
;==============================================================
.cseg                           ; daqui em diante os enderecos sao da flash (programa)
.org 0x0000                     ; endereco do vetor de reset
    jmp inicio                  ; ao ligar, o PC vai para 0 e salta para a inicializacao
.org OC1Aaddr                   ; endereco do vetor "Timer1 compare A"
    jmp isr_timer1              ; o hardware salta para a ISR do Timer1
.org OC0Aaddr                   ; endereco do vetor "Timer0 compare A"
    jmp isr_timer0              ; comparacao A do Timer0 (a cada 2 ms)
.org UDREaddr                   ; endereco do vetor "USART data register empty"
    jmp isr_usart_udre          ; USART: registrador de transmissao vazio (UDRE)
.org INT_VECTORS_SIZE           ; pula o espaco dos vetores; o codigo comeca aqui

;==============================================================
; BLOCO 8 - INICIALIZACAO (roda uma unica vez ao ligar)
;==============================================================
inicio:

    ; --- Pilha: aponta o SP para o fim da SRAM ---
    ; rcall/ret e as interrupcoes usam a pilha; sem ela o programa
    ; nao funciona. O SP comeca no ultimo endereco da memoria.
    ldi r16, high(RAMEND)       ; byte alto do ultimo endereco da SRAM
    out SPH, r16                ; escreve no byte alto do stack pointer
    ldi r16, low(RAMEND)        ; byte baixo do ultimo endereco da SRAM
    out SPL, r16                ; escreve no byte baixo do stack pointer

    ; --- PORTB: PB0..PB5 como saida (S1 e S4) ---
    ; A sequencia in/andi/ori/out mexe so nos bits dos semaforos e
    ; preserva PB6/PB7, que levam o cristal de 16 MHz.
    in   r16, DDRB              ; le a direcao atual do PORTB
    ori  r16, 0b00111111        ; marca PB0..PB5 como saida, sem tocar PB6/PB7
    out  DDRB, r16              ; grava a nova direcao do PORTB
    in   r16, PORTB             ; le o estado atual das saidas do PORTB
    andi r16, 0b11000000        ; zera PB0..PB5 e apaga as lampadas de S1 e S4
    out  PORTB, r16             ; grava, deixando as lampadas apagadas

    ; --- PORTD: PD2..PD7 como saida (S2 e S3); PD0/PD1 intocados ---
    ; PD0/PD1 sao o RX/TX da serial e nao podem ser mexidos aqui.
    in   r16, DDRD              ; le a direcao atual do PORTD
    ori  r16, 0b11111100        ; marca PD2..PD7 como saida e preserva PD0/PD1
    out  DDRD, r16              ; grava a nova direcao do PORTD
    in   r16, PORTD             ; le o estado atual das saidas do PORTD
    andi r16, 0b00000011        ; zera PD2..PD7 e apaga as lampadas de S2 e S3
    out  PORTD, r16             ; grava, deixando as lampadas apagadas

    ; --- PORTC: PC0..PC3 (CD4511) e PC4 (selecao) como saida ---
    ; PC5 fica livre e PC6 e o reset, entao nenhum dos dois e tocado.
    in   r16, DDRC              ; le a direcao atual do PORTC
    ori  r16, 0b00011111        ; marca PC0..PC4 como saida
    out  DDRC, r16              ; grava a nova direcao do PORTC
    in   r16, PORTC             ; le o estado atual das saidas do PORTC
    andi r16, 0b11100000        ; zera PC0..PC4 (BCD = 0 e selecao na unidade)
    out  PORTC, r16             ; grava o estado inicial do PORTC

    ; --- Cruzamento: entra no estado 0 (todos em vermelho) ---
    clr  digito_atual           ; comeca a multiplexacao pela unidade
    clr  estado_atual           ; seleciona o estado 0 da tabela
    rcall carrega_estado        ; acende as lampadas do estado 0 e carrega sua duracao

    ; --- S2 no vermelho, faltando S2_INICIAL (33) s ---
    ldi  cor_s2, 0              ; cor atual do S2 = vermelho
    ldi  tempo_s2, S2_INICIAL   ; segundos que faltam para o S2 abrir (33)
    rcall converte_bcd2         ; separa esse tempo em dezena e unidade para o display

    ; --- Timer1: CTC, prescale /256, TOP = 62499 -> base de 1 s ---
    ; Os registradores do Timer1 ficam na faixa estendida de I/O,
    ; por isso usamos lds/sts no lugar de in/out.
    ldi r16, 0                  ; valor 0 para desligar a saida PWM
    sts TCCR1A, r16             ; TCCR1A = 0 (nenhuma forma de onda nos pinos)
    ldi r16, high(62499)        ; byte alto do TOP (o alto entra primeiro)
    sts OCR1AH, r16             ; grava a parte alta de OCR1A
    ldi r16, low(62499)         ; byte baixo do TOP
    sts OCR1AL, r16             ; grava a parte baixa de OCR1A
    ldi r16, (1<<WGM12)|(1<<CS12) ; modo CTC (WGM12) e prescale /256 (CS12)
    sts TCCR1B, r16             ; configura o modo e a fonte de clock do Timer1
    lds r16, TIMSK1             ; le a mascara de interrupcoes do Timer1
    ori r16, (1<<OCIE1A)        ; habilita a interrupcao de comparacao do canal A
    sts TIMSK1, r16             ; grava a mascara atualizada

    ; --- Timer0: CTC, prescale /256, TOP = 124 -> base de 2 ms ---
    ; TCCR0A, TCCR0B e OCR0A ficam na faixa baixa de I/O, entao aqui
    ; da para usar out.
    ldi r16, (1<<WGM01)         ; modo CTC (TOP = OCR0A)
    out TCCR0A, r16             ; configura o modo de operacao do Timer0
    ldi r16, 124               ; TOP = 124 -> 125 contagens = 2 ms
    out OCR0A, r16             ; grava o valor de comparacao do Timer0
    ldi r16, (1<<CS02)         ; prescale /256
    out TCCR0B, r16            ; define a fonte de clock do Timer0
    lds r16, TIMSK0           ; TIMSK0 fica na faixa estendida, entao usa lds
    ori r16, (1<<OCIE0A)       ; habilita a interrupcao de comparacao do canal A
    sts TIMSK0, r16           ; grava a mascara atualizada

    ; --- USART: 9600 8N1, so TX, por interrupcao ---
    rcall init_usart            ; configura a USART (detalhes no BLOCO 16)

    ; --- Liga as interrupcoes globais (bit I do SREG) ---
    sei                         ; a partir daqui as tres ISRs podem ser atendidas

    ; --- Envia o status inicial dos quatro semaforos pela serial ---
    rcall envia_status          ; dispara a primeira mensagem de status

;==============================================================
; BLOCO 9 - LACO PRINCIPAL (fica vazio de proposito)
;--------------------------------------------------------------
; Como as interrupcoes cuidam de tudo, o main nao precisa ficar
; checando nada: ele so gira em um laco infinito esperando os
; eventos.
;==============================================================
loop_principal:
    rjmp loop_principal         ; laco infinito vazio: espera as interrupcoes

;==============================================================
; BLOCO 10 - ISR DO TIMER1 (executa a cada 1 s)
;--------------------------------------------------------------
; A cada segundo esta rotina faz tres coisas:
;   a) cruzamento: tira 1 do tempo do estado e, quando ele zera,
;      avanca para o proximo estado, trocando as 12 lampadas;
;   b) S2: tira 1 do tempo da cor atual e, quando ele zera, passa
;      para a proxima cor e recarrega a duracao dela (64, 87 ou 4 s);
;   c) atualiza os dois digitos do display.
; Como toda ISR, ela salva e restaura o SREG e os registradores que
; usa, para nao atrapalhar o codigo que foi interrompido.
;==============================================================
isr_timer1:
    push r16                    ; guarda r16 na pilha
    in   r16, SREG              ; le o registrador de status (as flags)
    push r16                    ; guarda o SREG na pilha
    push r17                    ; guarda r17 (carrega_estado usa esse registrador)
    push ZL                     ; guarda a parte baixa do ponteiro Z
    push ZH                     ; guarda a parte alta do ponteiro Z

    ; --- a) Cruzamento: tira 1 do estado e avanca quando zera ---
    dec  contador_estado        ; passou mais 1 s no estado atual
    brne t1_s2                  ; se o estado ainda nao acabou, vai cuidar do S2
    inc  estado_atual           ; o estado acabou, entao vai para o proximo
    cpi  estado_atual, NUM_ESTADOS ; passou do ultimo estado da tabela?
    brlo t1_troca               ; se ainda e um estado valido, segue
    clr  estado_atual           ; fim do ciclo: volta ao estado 0 (todos vermelhos)
t1_troca:
    rcall carrega_estado        ; acende as lampadas do novo estado e carrega a duracao
    rcall envia_status          ; como o estado mudou, envia o status dos 4 semaforos

    ; --- b) Contador do S2: tira 1 da cor e troca quando zera ---
t1_s2:
    dec  tempo_s2               ; passou mais 1 s na cor atual do S2
    brne t1_mostra              ; se o S2 ainda nao muda de cor, vai direto ao display
    inc  cor_s2                 ; troca de cor: vermelho -> verde -> amarelo
    cpi  cor_s2, 3              ; passou do amarelo (cor 2)?
    brlo t1_cor                 ; se ainda e uma cor valida (0 a 2), segue
    clr  cor_s2                 ; volta ao vermelho (cor 0)
t1_cor:
    rcall carrega_tempo_s2      ; recarrega tempo_s2 com a duracao da nova cor

    ; --- c) Atualiza os digitos mostrados no display ---
t1_mostra:
    rcall converte_bcd2         ; separa tempo_s2 em dezena e unidade

    pop  ZH                     ; recupera a parte alta de Z
    pop  ZL                     ; recupera a parte baixa de Z
    pop  r17                    ; recupera r17
    pop  r16                    ; recupera o valor que estava no SREG
    out  SREG, r16              ; restaura as flags
    pop  r16                    ; recupera r16
    reti                        ; volta da interrupcao e religa o bit I

;==============================================================
; BLOCO 11 - ISR DO TIMER0 (executa a cada 2 ms): MULTIPLEXACAO
;--------------------------------------------------------------
; A cada chamada a rotina alterna entre mostrar a dezena e mostrar
; a unidade. Isso acontece 500 vezes por segundo, rapido demais
; para o olho perceber, entao parece que os dois digitos ficam
; acesos ao mesmo tempo. Se a dezena esta apagada (zero a esquerda),
; a rotina fica so na unidade, que entao acende o tempo todo.
;==============================================================
isr_timer0:
    push r16                    ; guarda r16 na pilha
    in   r16, SREG              ; le o SREG (as flags)
    push r16                    ; guarda o SREG na pilha
    push r17                    ; guarda r17, que carrega o digito a mostrar

    ; --- Alterna a fase: 1 = dezena, 0 = unidade ---
    ldi  r16, 1                 ; mascara do bit 0
    eor  digito_atual, r16      ; inverte a fase (0 vira 1, 1 vira 0) a cada chamada
    cpi  dezena, APAGADO        ; a dezena esta apagada (zero a esquerda)?
    brne mux_escolhe            ; se a dezena existe, segue normalmente
    clr  digito_atual           ; se esta apagada, forca a fase para a unidade

    ; --- Escolhe o digito da fase atual ---
mux_escolhe:
    mov  r17, unidade           ; parte supondo que vai mostrar a unidade
    tst  digito_atual           ; a fase e dezena (digito_atual diferente de 0)?
    breq mux_dado               ; se e a unidade, nao troca
    mov  r17, dezena            ; na fase da dezena, mostra a dezena

    ; --- Coloca o digito BCD em PC0..PC3 e preserva PC4..PC7 ---
    ; PC0..PC3 vao para as entradas A..D do CD4511.
mux_dado:
    in   r16, PORTC             ; le o PORTC atual
    andi r16, 0b11110000        ; zera so os 4 bits do BCD e preserva PC4..PC7
    or   r16, r17               ; encaixa o digito escolhido em PC0..PC3
    out  PORTC, r16             ; manda o BCD para o CD4511

    ; --- PC4 escolhe qual display acende ---
    tst  digito_atual           ; a fase e a dezena?
    breq mux_unidade            ; se e a unidade, vai desligar o NPN
    sbi  PORTC, 4               ; PC4 = 1 -> o transistor conduz e acende a dezena
    rjmp mux_fim                ; encerra a multiplexacao desta vez
mux_unidade:
    cbi  PORTC, 4               ; PC4 = 0 -> o pino puxa o catodo e acende a unidade

mux_fim:
    pop  r17                    ; recupera r17
    pop  r16                    ; recupera o valor que estava no SREG
    out  SREG, r16              ; restaura as flags
    pop  r16                    ; recupera r16
    reti                        ; volta da interrupcao

;==============================================================
; BLOCO 12 - ISR DA USART (UDRE): registrador de transmissao vazio
;--------------------------------------------------------------
; Esta rotina manda a mensagem de status um byte por vez, sem parar
; o resto do programa. O hardware a chama sempre que o UDR0 fica
; vazio e a UDRIE0 esta ligada. O ponteiro X aponta para o proximo
; caractere (ver envia_status). Quando chega ao 0 que termina a
; mensagem, a rotina desliga a propria interrupcao para nao
; disparar a toa.
;==============================================================
isr_usart_udre:
    push r16                    ; guarda r16 na pilha
    in   r16, SREG              ; le o SREG (as flags)
    push r16                    ; guarda o SREG na pilha

    ld   r16, X+                ; le o proximo caractere e avanca o ponteiro X
    tst  r16                    ; esse caractere e o 0 que termina a mensagem?
    breq udre_fim               ; se for o fim, vai desligar a interrupcao
    sts  UDR0, r16              ; coloca o caractere no registrador de transmissao
    rjmp udre_ret               ; sai mantendo a interrupcao ligada para o proximo byte
udre_fim:
    lds  r16, UCSR0B            ; le o registrador de controle B da USART
    cbr  r16, (1<<UDRIE0)       ; limpa o UDRIE0, porque nao ha mais nada a enviar
    sts  UCSR0B, r16            ; grava e desliga a interrupcao de registrador vazio
udre_ret:
    pop  r16                    ; recupera o valor que estava no SREG
    out  SREG, r16              ; restaura as flags
    pop  r16                    ; recupera r16
    reti                        ; volta da interrupcao

;==============================================================
; BLOCO 13 - carrega_estado: acende as lampadas do estado atual
;--------------------------------------------------------------
; Le a linha do estado na tabela_estados, onde cada linha tem 4
; bytes (PORTB, PORTD, duracao, 0), e aplica os dois primeiros com
; dois OUT. Usa Z como ponteiro para a flash (lpm) e preserva os
; bits do cristal (PB6/PB7) e da serial (PD0/PD1).
; Entrada: estado_atual. Saida: PORTB, PORTD e contador_estado.
;==============================================================
carrega_estado:
    ldi  ZL, low(tabela_estados*2)  ; Z aponta para a tabela (endereco em bytes)
    ldi  ZH, high(tabela_estados*2) ; parte alta do endereco da tabela
    mov  r16, estado_atual          ; copia o indice do estado
    lsl  r16                        ; multiplica por 2
    lsl  r16                        ; multiplica por 4: cada linha tem 4 bytes
    add  ZL, r16                    ; soma o deslocamento a parte baixa de Z
    clr  r17                        ; zera r17 para propagar o carry
    adc  ZH, r17                    ; leva o carry para a parte alta de Z

    lpm  r16, Z+                    ; le o 1o byte: lampadas de S1 e S4 (PORTB)
    in   r17, PORTB                 ; le o PORTB atual
    andi r17, 0b11000000            ; preserva PB6/PB7 (cristal) e zera o resto
    or   r17, r16                   ; junta as lampadas do estado
    out  PORTB, r17                 ; acende S1 e S4

    lpm  r16, Z+                    ; le o 2o byte: lampadas de S2 e S3 (PORTD)
    in   r17, PORTD                 ; le o PORTD atual
    andi r17, 0b00000011            ; preserva PD0/PD1 (serial) e zera o resto
    or   r17, r16                   ; junta as lampadas do estado
    out  PORTD, r17                 ; acende S2 e S3

    lpm  contador_estado, Z         ; le o 3o byte: duracao do estado em segundos
    ret                             ; volta para quem chamou

;==============================================================
; BLOCO 14 - carrega_tempo_s2: pega a duracao da cor atual do S2
;--------------------------------------------------------------
; Le na tabela_s2 (um byte por cor) a duracao da cor indicada por
; cor_s2 e devolve em tempo_s2.
; Entrada: cor_s2 (0, 1 ou 2). Saida: tempo_s2.
;==============================================================
carrega_tempo_s2:
    ldi  ZL, low(tabela_s2*2)   ; Z aponta para a tabela de tempos do S2
    ldi  ZH, high(tabela_s2*2)  ; parte alta do endereco da tabela
    add  ZL, cor_s2             ; soma o indice da cor (um byte por cor)
    clr  r17                    ; zera r17 para propagar o carry
    adc  ZH, r17                ; leva o carry para a parte alta de Z
    lpm  tempo_s2, Z            ; le na flash a duracao daquela cor
    ret                         ; volta para quem chamou

;==============================================================
; BLOCO 15 - converte_bcd2: separa tempo_s2 (0 a 99) em dezena e unidade
;--------------------------------------------------------------
; Faz a conversao tirando 10 varias vezes, porque o AVR nao tem
; instrucao de divisao. Se a dezena der 0, ela vira APAGADO, assim
; o display nao mostra zero a esquerda.
; Entrada: tempo_s2. Saida: dezena e unidade.
;==============================================================
converte_bcd2:
    mov  r16, tempo_s2          ; copia o tempo para um registrador de trabalho
    clr  dezena                 ; comeca a contagem da dezena em 0
cb_dezena:
    cpi  r16, 10                ; ainda sobram pelo menos 10 para tirar?
    brlo cb_unidade             ; se sobrou menos de 10, o resto e a unidade
    subi r16, 10                ; tira 10 do valor
    inc  dezena                 ; conta mais uma dezena
    rjmp cb_dezena              ; repete ate sobrar menos de 10
cb_unidade:
    mov  unidade, r16           ; o que sobrou (0 a 9) e a unidade

    tst  dezena                 ; a dezena ficou em 0?
    brne cb_fim                 ; se nao, mantem o valor da dezena
    ldi  dezena, APAGADO        ; dezena 0 -> marca para apagar (sem zero a esquerda)
cb_fim:
    ret                         ; volta para quem chamou

;==============================================================
; BLOCO 16 - init_usart: configura a USART0 so para transmissao
;--------------------------------------------------------------
; Baud 9600 a 16 MHz, com U2X0 = 0:
;   UBRR = Fosc/(16*baud) - 1 = 16000000/(16*9600) - 1
;        = 104,17 - 1 = 103,17, que arredonda para 103.
;   O baud real fica em 16000000/(16*(103+1)) = 9615 Hz, um erro de
;   +0,16%, aceitavel para 8N1.
; O formato 8N1 significa 8 bits de dados, sem paridade e 1 stop
; bit. So o transmissor (TXEN0) e ligado; a USART assume PD1 como
; TX e deixa PD0 livre. A UDRIE0 so entra quando ha algo a enviar
; (em envia_status), para nao disparar a toa. Os registradores da
; USART ficam na faixa estendida, entao usamos lds/sts.
;==============================================================
init_usart:
    ldi  r16, high(103)                ; byte alto do UBRR (= 0)
    sts  UBRR0H, r16                   ; grava a parte alta do baud rate
    ldi  r16, low(103)                 ; byte baixo do UBRR (= 103)
    sts  UBRR0L, r16                   ; grava a parte baixa do baud rate
    ldi  r16, (1<<UCSZ01)|(1<<UCSZ00)  ; seleciona 8 bits de dados
    sts  UCSR0C, r16                   ; grava o formato (8N1)
    ldi  r16, (1<<TXEN0)               ; habilita so o transmissor
    sts  UCSR0B, r16                   ; liga o TX e deixa o RX desligado
    ret                                ; volta para quem chamou

;==============================================================
; BLOCO 17 - envia_status: monta a mensagem e comeca o envio
;--------------------------------------------------------------
; Monta a linha de status no buffer, aponta X para o inicio dele e
; liga a UDRIE0. A partir dai a ISR da UDRE esvazia o buffer byte a
; byte, sem parar o resto do programa.
; Um envio completo (cerca de 90 bytes a 9600) leva perto de 95 ms,
; bem menos que o estado mais curto do cruzamento (1 s). Por isso
; nunca ha dois envios ao mesmo tempo e da para reapontar X aqui
; com seguranca. Usa r16 (salvo pela ISR do Timer1, de onde esta
; rotina tambem e chamada) e X (reservado).
;==============================================================
envia_status:
    rcall monta_mensagem        ; escreve a linha de status no msg_buffer
    ldi  XL, low(msg_buffer)    ; X aponta para o inicio do buffer (parte baixa)
    ldi  XH, high(msg_buffer)   ; parte alta do endereco do buffer
    lds  r16, UCSR0B            ; le o registrador de controle B da USART
    sbr  r16, (1<<UDRIE0)       ; liga a interrupcao de registrador de dados vazio
    sts  UCSR0B, r16            ; grava, e o envio por interrupcao comeca
    ret                         ; volta para quem chamou

;==============================================================
; BLOCO 18 - monta_mensagem: escreve a linha de status no buffer
;--------------------------------------------------------------
; Monta no msg_buffer a linha:
;  "Semaforo 1 - COR; Semaforo 2 - COR; Semaforo 3 - COR; Semaforo 4 - COR\r\n"
; A cor de cada semaforo vem do estado real das portas (PORTB e
; PORTD) que a maquina de estados acabou de escrever, entao a
; logica das cores nao precisa ser repetida aqui. Cada semaforo
; ocupa tres bits (vermelho, amarelo, verde); a rotina desloca
; esses bits para as posicoes 0, 1 e 2 e deixa cor_ptr escolher a
; palavra certa ("Vermelho", "Amarelo" ou "Verde"). A rotina se
; vira sozinha: salva tudo que usa.
;   Y = ponteiro de escrita no buffer; Z = origem na flash.
;==============================================================
monta_mensagem:
    push r16                    ; guarda r16
    push r17                    ; guarda r17, que carrega os bits do semaforo
    push YL                     ; guarda a parte baixa de Y
    push YH                     ; guarda a parte alta de Y
    push ZL                     ; guarda a parte baixa de Z
    push ZH                     ; guarda a parte alta de Z

    ldi  YL, low(msg_buffer)    ; Y aponta para o inicio do buffer (parte baixa)
    ldi  YH, high(msg_buffer)   ; parte alta do endereco do buffer

    ; --- S1: PORTB bits 0, 1 e 2 (ja alinhados) ---
    ldi  ZL, low(t_s1*2)        ; Z aponta para o texto "Semaforo 1 - "
    ldi  ZH, high(t_s1*2)       ; parte alta do endereco do texto
    rcall copia_flash           ; copia o texto para o buffer
    in   r17, PORTB             ; le o estado real do PORTB
    andi r17, 0b00000111        ; isola os 3 bits do S1 (posicoes 0, 1 e 2)
    rcall cor_ptr               ; escolhe a string da cor do S1
    rcall copia_flash           ; copia o nome da cor para o buffer

    ; --- S2: PORTD bits 2, 3 e 4 (desloca 2 para a direita) ---
    ldi  ZL, low(t_s2*2)        ; Z aponta para o texto "; Semaforo 2 - "
    ldi  ZH, high(t_s2*2)       ; parte alta do endereco do texto
    rcall copia_flash           ; copia o texto para o buffer
    in   r17, PORTD             ; le o estado real do PORTD
    lsr  r17                    ; desloca 1 bit para a direita
    lsr  r17                    ; desloca mais 1: o S2 cai nas posicoes 0, 1 e 2
    andi r17, 0b00000111        ; isola os 3 bits do S2
    rcall cor_ptr               ; escolhe a string da cor do S2
    rcall copia_flash           ; copia o nome da cor para o buffer

    ; --- S3: PORTD bits 5, 6 e 7 (swap e lsr levam para 0, 1 e 2) ---
    ldi  ZL, low(t_s3*2)        ; Z aponta para o texto "; Semaforo 3 - "
    ldi  ZH, high(t_s3*2)       ; parte alta do endereco do texto
    rcall copia_flash           ; copia o texto para o buffer
    in   r17, PORTD             ; le o estado real do PORTD
    swap r17                    ; troca os nibbles (bits 5, 6 e 7 vao para 1, 2 e 3)
    lsr  r17                    ; desloca 1: o S3 cai nas posicoes 0, 1 e 2
    andi r17, 0b00000111        ; isola os 3 bits do S3
    rcall cor_ptr               ; escolhe a string da cor do S3
    rcall copia_flash           ; copia o nome da cor para o buffer

    ; --- S4: PORTB bits 3, 4 e 5 (desloca 3 para a direita) ---
    ldi  ZL, low(t_s4*2)        ; Z aponta para o texto "; Semaforo 4 - "
    ldi  ZH, high(t_s4*2)       ; parte alta do endereco do texto
    rcall copia_flash           ; copia o texto para o buffer
    in   r17, PORTB             ; le o estado real do PORTB
    lsr  r17                    ; desloca 1 bit para a direita
    lsr  r17                    ; desloca mais 1
    lsr  r17                    ; desloca mais 1: o S4 cai nas posicoes 0, 1 e 2
    andi r17, 0b00000111        ; isola os 3 bits do S4
    rcall cor_ptr               ; escolhe a string da cor do S4
    rcall copia_flash           ; copia o nome da cor para o buffer

    ; --- Fim de linha (CR LF) e o 0 que termina a mensagem ---
    ldi  ZL, low(t_fim*2)       ; Z aponta para o texto de fim de linha (CR LF)
    ldi  ZH, high(t_fim*2)      ; parte alta do endereco
    rcall copia_flash           ; copia CR LF para o buffer
    clr  r16                    ; valor 0, que marca o fim da mensagem
    st   Y+, r16                ; grava o 0 no fim do buffer (a ISR para nele)

    pop  ZH                     ; recupera a parte alta de Z
    pop  ZL                     ; recupera a parte baixa de Z
    pop  YH                     ; recupera a parte alta de Y
    pop  YL                     ; recupera a parte baixa de Y
    pop  r17                    ; recupera r17
    pop  r16                    ; recupera r16
    ret                         ; volta para quem chamou

;==============================================================
; BLOCO 19 - copia_flash: copia uma string da flash para o buffer
;--------------------------------------------------------------
; Copia byte a byte de Z (uma string terminada em 0) para Y, sem
; copiar o 0. Y e Z avancam, entao varias chamadas seguidas vao
; preenchendo o buffer. Usa r16.
;==============================================================
copia_flash:
cf_laco:
    lpm  r16, Z+                ; le um byte da string na flash e avanca Z
    tst  r16                    ; esse byte e o 0 que termina a string?
    breq cf_fim                 ; se for o fim, para de copiar
    st   Y+, r16                ; grava o byte no buffer e avanca Y
    rjmp cf_laco                ; repete para o proximo byte
cf_fim:
    ret                         ; volta para quem chamou

;==============================================================
; BLOCO 20 - cor_ptr: escolhe a palavra da cor a partir dos bits
;--------------------------------------------------------------
; Recebe em r17 os tres bits da cor (bit0 = vermelho, bit1 =
; amarelo, bit2 = verde; so um fica aceso) e devolve em Z o
; endereco da string correspondente na flash.
; Entrada: r17. Saida: Z aponta para a string da cor.
;==============================================================
cor_ptr:
    sbrc r17, 0                 ; o bit do vermelho esta aceso?
    rjmp cp_verm                ; se sim, aponta para "Vermelho"
    sbrc r17, 1                 ; o bit do amarelo esta aceso?
    rjmp cp_amar                ; se sim, aponta para "Amarelo"
    ldi  ZL, low(c_verd*2)      ; se nao e vermelho nem amarelo, e verde
    ldi  ZH, high(c_verd*2)     ; parte alta do endereco de "Verde"
    ret                         ; volta com Z apontando para "Verde"
cp_verm:
    ldi  ZL, low(c_verm*2)      ; Z aponta para "Vermelho" (parte baixa)
    ldi  ZH, high(c_verm*2)     ; parte alta do endereco de "Vermelho"
    ret                         ; volta com Z apontando para "Vermelho"
cp_amar:
    ldi  ZL, low(c_amar*2)      ; Z aponta para "Amarelo" (parte baixa)
    ldi  ZH, high(c_amar*2)     ; parte alta do endereco de "Amarelo"
    ret                         ; volta com Z apontando para "Amarelo"

;==============================================================
; BLOCO 21 - TABELA DE TEMPOS DO S2 (na flash)
;--------------------------------------------------------------
; Um byte por cor, na ordem em que as cores aparecem. O
; carrega_tempo_s2 usa cor_s2 como indice nesta tabela.
;==============================================================
tabela_s2:
    .db S2_VERMELHO, S2_VERDE, S2_AMARELO, 0   ; vermelho, verde, amarelo; o 0 so alinha

;==============================================================
; BLOCO 22 - TABELA DE ESTADOS DO CRUZAMENTO (na flash)
;--------------------------------------------------------------
; Uma linha por estado, com 4 bytes cada: PORTB, PORTD, duracao, 0.
;
; Bits do PORTB:  - - S4v S4a S4r S1v S1a S1r   (bit 0 = S1 vermelho)
; Bits do PORTD:  S3v S3a S3r S2v S2a S2r - -   (bit 2 = S2 vermelho)
;
; O estado 0 junta os dois trechos de "todos em vermelho" do
; cronograma (de 2m23s a 2m35s mais de 0s a 21s = 12 + 21 = 33 s).
; Por isso a simulacao comeca 12 s antes do T = 0 do cronograma:
;     tempo no cronograma = tempo da simulacao - 12 s
;
;            PORTB       PORTD       dur  -   ; cronograma   S1  S2  S3  S4
;==============================================================
tabela_estados:
    .db 0b00001001, 0b00100100, 33, 0  ; 0: 143 -  21 s  R   R   R   R
    .db 0b00001001, 0b10010000, 22, 0  ; 1:  21 -  43 s  R   G   G   R
    .db 0b00001001, 0b01010000,  4, 0  ; 2:  43 -  47 s  R   G   A   R
    .db 0b00001100, 0b00110000, 60, 0  ; 3:  47 - 107 s  G   G   R   R
    .db 0b00001010, 0b00110000,  1, 0  ; 4: 107 - 108 s  A   G   R   R
    .db 0b00001010, 0b00101000,  3, 0  ; 5: 108 - 111 s  A   A   R   R
    .db 0b00001001, 0b00101000,  1, 0  ; 6: 111 - 112 s  R   A   R   R
    .db 0b00001001, 0b00100100,  1, 0  ; 7: 112 - 113 s  R   R   R   R
    .db 0b00100001, 0b00100100, 25, 0  ; 8: 113 - 138 s  R   R   R   G
    .db 0b00010001, 0b00100100,  5, 0  ; 9: 138 - 143 s  R   R   R   A

;==============================================================
; BLOCO 23 - TEXTOS FIXOS DA MENSAGEM DE STATUS (na flash)
;--------------------------------------------------------------
; Cada string termina em 0, que o copia_flash usa para saber onde
; parar. Quando a string tem um numero impar de bytes, o montador
; completa com um 0 de alinhamento; esse byte extra fica depois do
; terminador e nao atrapalha.
;==============================================================
t_s1:   .db "Semaforo 1 - ", 0       ; prefixo do S1
t_s2:   .db "; Semaforo 2 - ", 0     ; separador e prefixo do S2
t_s3:   .db "; Semaforo 3 - ", 0     ; separador e prefixo do S3
t_s4:   .db "; Semaforo 4 - ", 0     ; separador e prefixo do S4
t_fim:  .db 13, 10, 0                ; CR LF: fim de linha legivel no monitor serial

c_verm: .db "Vermelho", 0            ; nome da cor vermelha
c_amar: .db "Amarelo", 0             ; nome da cor amarela
c_verd: .db "Verde", 0               ; nome da cor verde
