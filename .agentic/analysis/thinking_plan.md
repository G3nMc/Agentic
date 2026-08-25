# Piano di sviluppo: storico del thinking in ConversationHistory

**Obiettivo**: conservare la storia del thinking del modello per sessione dentro
`ConversationHistory` (bin/agent/loop/history.py), in modo che il modello abbia
sotto controllo il proprio ragionamento pregresso, senza toccare il comportamento
attuale della UI (strip live, filtri `":"`, ecc.).

**Stato attuale (verificato nel codice)**
- `ConversationHistory` (history.py) tiene:
  - `_system_prompts: Dict[str, str]` (prompt di sistema keyed)
  - `_turns: List[Dict[str, str]]` (turni user/assistant/tool puliti)
  - `task_tracker: TaskTracker` (stato task-flow)
- Il thinking oggi è SOLO un flusso live:
  - `emit_thinking()` in task_protocol.py emette `<event type="thinking">` su stdout
  - `run_loop.py` lo chiama in 3 punti: `_run_chat_only` (riga ~977/991),
    tool loop (riga ~1064-1066), e nel percorso di synthesis
  - il testo NON viene salvato da nessuna parte: a fine turno è perso
- `to_messages()` costruisce la lista per il modello: system block + `_turns`.
  Il thinking non entra MAI nel contesto del modello.

## Fase 1 — Raccolta del thinking per turno (run_loop.py)

1. Aggiungere a `_TurnState` un campo `thinking_parts: List[str]` (default_factory=list).
2. Creare un helper `_emit_and_record_thinking(text)` nell'Orchestrator che:
   - chiama `emit_thinking(text)` (comportamento UI invariato)
   - se il testo pulito non è vuoto, lo appende a `self._turn.thinking_parts`
   - NOTA: `emit_thinking` già scarta chunk vuoti/`":"`; l'helper deve applicare
     la stessa pulizia prima di registrare (o riusare una funzione condivisa).
3. Sostituire le 3 chiamate dirette a `emit_thinking(...)` con l'helper.
4. Il turno si chiude in `run()`: prima di ogni `return` (o in un `finally`),
   chiamare `self._flush_turn_thinking()` che:
   - unisce `thinking_parts` in un unico testo (separatore `\n`)
   - se non vuoto, lo salva in `ConversationHistory` (vedi Fase 2)
   - azzera `thinking_parts`
   - ATTENZIONE: `run()` ha molti punti di uscita (`_Bail`, eccezioni, return
     diretti). Il flush va messo in un `try/finally` attorno al corpo di `run()`
     per non perdere il thinking in caso di bail/errore.

## Fase 2 — Storage in ConversationHistory (history.py)

1. Nuovo stato in `ConversationHistory.__init__`:
   - `self._thinking_history: List[Dict[str, str]] = []`
   - ogni voce: `{"role": "assistant", "content": "<thinking>", "thinking": True}`
     oppure una struttura dedicata `{"turn": N, "text": "..."}` — decidere in
     implementazione; la forma a dict è più semplice da filtrare.
2. Nuovi metodi:
   - `add_thinking(text: str) -> None`: appende una voce alla storia del thinking
   - `thinking_history` (property read-only): restituisce la lista
   - `clear_thinking() -> None`: svuota (chiamato da `reset_all()`)
   - `last_thinking() -> Optional[str]`: ultimo thinking registrato
3. `reset_all()` deve chiamare `clear_thinking()`.
4. `copy()` deve copiare anche `_thinking_history` (shallow copy della lista).
5. `sanitize()` deve sanitizzare anche i testi del thinking (stessa
   `_sanitize_text` già usata per i turni).

## Fase 3 — Esposizione al modello (opzionale, da decidere)

Il requisito è "fargli avere sotto controllo la storia del thinking in una
sessione". Due opzioni, da scegliere in implementazione:

**Opzione A — system prompt keyed (consigliata)**
- Nuova chiave `"thinking_history"` in `_system_prompts`.
- `sync_thinking_state()` (simmetrico a `sync_task_state()`) renderizza la storia
  in un blocco testuale compatto (es. ultimi N thinking, troncati a ~2000 char
  totali) e la mette/rimuove dalla chiave.
- Chiamare `sync_thinking_state()` prima di ogni chiamata modello (accanto a
  `sync_task_state()`).
- Pro: il modello vede la storia senza inquinare i turni; il trimming dei turni
  non la tocca; facile da disabilitare.
- Contro: consuma token di sistema.

**Opzione B — turni dedicati**
- Iniettare il thinking come turno `assistant` con prefisso `[thinking] ...`.
- Contro: sporca i turni puliti, viene trimmato insieme alla conversazione,
  rischia di confondere il modello. Sconsigliata.

Raccomandazione: **Opzione A**, con cap configurabile (es. ultimi 5 thinking,
max ~2000 caratteri totali, troncamento dal più vecchio).

## Fase 4 — Persistenza tra richieste (già coperta)

`ConversationHistory` vive nell'Orchestrator per l'intera sessione (il client
Flutter riusa la stessa istanza tra i messaggi). Quindi lo storico del thinking
sopravvive automaticamente tra i turni della stessa sessione. Nessun DB
necessario per questo requisito. (Se in futuro servirà persistenza su disco,
valutare il DB messaggi lato Flutter — fuori scope.)

## Fase 5 — Test

Creare `tests/test_thinking_history.py` (o estendere i test esistenti in
`bin/agent/loop/` se presenti):
- `add_thinking` appende e `last_thinking` restituisce l'ultimo
- `reset_all` svuota anche il thinking
- `copy` non condivide la lista
- `sanitize` pulisce i testi del thinking
- `sync_thinking_state` produce/rimuove la chiave `thinking_history`
- il flush di `_TurnState` unisce i chunk e azzera la lista
- `emit_thinking` continua a scartare chunk vuoti/`":"` (regressione)

## Fase 6 — Validazione

- `python_check` su `bin/agent/loop` (e `bin/agent` se toccati altri file)
- `python_lint` sugli stessi path
- `python_test` sui test nuovi/esistenti
- `flutter_analyze` (root) NON necessario se non si tocca Dart — ma eseguirlo
  comunque se il piano cambia lato UI (non previsto).

## Rischi / attenzioni

- **Token budget**: la storia del thinking consuma contesto. Usare un cap
  conservativo e troncamento dal più vecchio.
- **Doppia emissione**: l'helper unico evita che thinking venga emesso ma non
  registrato (o viceversa).
- **Flush su bail**: senza `try/finally` in `run()` il thinking si perde quando
  il loop esce via `_Bail` o eccezione.
- **Nessun cambiamento UI**: lo strip live resta com'è; questo piano aggiunge
  solo memoria lato orchestratore.