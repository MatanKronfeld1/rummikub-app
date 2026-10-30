# Autonomous Execution Plan: Logic, Solver Steps, DB & Challenges

## Phase 1: Database Setup & Data Models (Backend)
- [x] **Task 1.1: Database Initialization & Core Schemas**
  - Initialize DB (`db.py`) with models:
    - `GameSession` (id, userId, status: 'active'|'packed', createdAt)
    - `TurnHistory` (id, gameId, turnIndex, boardStateJson, rackStateJson, moveAppliedJson)
    - `CommunityChallenge` (id, initialBoardJson, initialRackJson, boardHash, aiScore, createdFromSessionId, turnIndex, UNIQUE(createdFromSessionId, turnIndex), UNIQUE(boardHash))
    - `Leaderboard` (userId, totalPoints, challengesWon)
  - Ensure ALL board/rack states are stored strictly as JSON (Tile schema: `{id, color, value, isJoker}`), NEVER as raw image bytes.
  - Test: Write `test_db.py` verifying schema initialization, deduplication constraints, and JSON payload storage.

## Phase 2: Step-by-Step Solver Transition Engine (Backend)
- [x] **Task 2.1: Step-by-Step Diff Generator**
  - Update `solver/` output payload to generate explicit `solution_steps`:
    - Step object schema: `{stepIndex, type: 'PLACE_FROM_RACK' | 'MOVE_BETWEEN_SETS' | 'FORM_NEW_SET' | 'DISBAND_SET', sourceSetId, targetSetId, tiles, description}`.
  - Compute exact delta between (initialBoard + initialRack) and final solved board.
  - Test: Write `test_solver_steps.py` verifying sequential step reconstruction and edge cases (pure board restructuring vs rack placement).

## Phase 3: Game Session & Challenge Logic Endpoints (Features B, C, D - Backend)
- [x] **Task 3.1: Session Lifecycle & Auto-Challenge Trigger**
  - Endpoint `POST /game/turn`: Record a turn in active `GameSession`.
  - Endpoint `POST /game/end`: Mark session as `packed` (cleared board, session ended, or manual trigger).
  - Auto-publish Hook: Upon successful `/solve`, automatically create an entry in `CommunityChallenge` with initial board & AI score.
  - Test: Write `test_game_flow.py` for session lifecycle and auto-publishing.

- [x] **Task 3.2: Challenge Scoring & Leaderboard Endpoints**
  - Endpoint `POST /challenge/{id}/submit`: Compare player placed tiles against AI placed tiles (`score = humanPlaced - aiPlaced`). Update user score in `Leaderboard`.
  - Endpoint `GET /challenge/list` and `GET /leaderboard`.
  - Test: Write `test_scoring.py` verifying point calculation and leaderboard rankings.

## Phase 4: Step-by-Step Visualizer UI (Feature A - Frontend)
- [x] **Task 4.1: Step-by-Step Stepper Widget**
  - Create `SolutionStepsViewer` widget in Flutter showing transitions step-by-step with arrows (`Source Set ➔ Target Set / Rack`).
  - Add "Next Step" / "Previous Step" interactive controls.
  - Test: Write widget test in `solution_steps_viewer_test.dart`.

## Phase 5: Game Session & End Game UX (Feature B - Frontend)
- [x] **Task 5.1: Game Lifecycle Controls**
  - Connect UI to `POST /game/turn` on each detection/solve.
  - Add prominent "End Game" button on header/drawer that terminates session and resets screen to fresh Tile Recognition mode.
  - Auto-end session when board is cleared or user logs out.
  - Test: Write widget test verifying "End Game" resets state to recognition mode.

## Phase 6: Community Challenge & Leaderboard Screens (Features C, D - Frontend)
- [x] **Task 6.1: Challenge Play & Leaderboard Views**
  - Build `CommunityChallengeScreen`: Choose challenge -> play turn -> calculate relative score vs AI.
  - Build `LeaderboardScreen`: Render player ranking table.
  - Test: Write widget test verifying score calculation and ranking display.