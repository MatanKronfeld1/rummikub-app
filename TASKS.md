# Autonomous Execution Plan: UI & UX Tile Editing Improvements

## Phase 1: Automatic Sorting Engine (Frontend)
- [x] **Task 1.1: Rack and Set Auto-Sorting Logic**
  - **Target Files:** `Project-Rummikub_frontend/lib/models/rummikub_tiles.dart`, `Project-Rummikub_frontend/lib/providers/game_provider.dart`, `Project-Rummikub_frontend/test/tile_sorting_test.dart`
  - Implement sorting helper function for tile lists: Sort primary by color (Black, Blue, Red, Yellow) and secondary by numeric value (1-13, Jokers at end).
  - Trigger auto-sort on rack immediately after AI detection completes.
  - Trigger auto-sort on rack/set whenever tiles are added, updated, or removed.
  - Test: Write `tile_sorting_test.dart` verifying correct sorting order after detection and after manual edits.
  - Verification: `flutter test Project-Rummikub_frontend/test/tile_sorting_test.dart` and `flutter analyze`

## Phase 2: Enhanced Tile Addition Menu (Frontend)
- [x] **Task 2.1: Visual Multi-Tile Picker Overlay Widget**
  - **Target Files:** `Project-Rummikub_frontend/lib/widgets/tile_picker_popover.dart`, `Project-Rummikub_frontend/test/tile_picker_popover_test.dart`
  - Build popover menu widget triggered by a `+` button.
  - Options display 4 color categories (Red, Blue, Black, Yellow) and a Joker option.
  - Hover/select color expands numbers 1-13. Hovering Joker expands Black/Red Joker options.
  - Add quantity editable field/stepper (default: 1, customizable to N).
  - Tapping a tile adds N copies of the selected tile to the designated target (set or rack).
  - Test: Write `tile_picker_popover_test.dart` testing color selection, number picker, quantity adjustments, and selection callback.
  - Verification: `flutter test Project-Rummikub_frontend/test/tile_picker_popover_test.dart` and `flutter analyze`

- [x] **Task 2.2: Integrate '+' Button into Board Sets and Rack**
  - **Target Files:** `Project-Rummikub_frontend/lib/screens/correction_screen.dart`, `Project-Rummikub_frontend/lib/widgets/rack_widget.dart`, `Project-Rummikub_frontend/test/tile_addition_integration_test.dart`
  - Add the `+` button UI element to each set container on the board and to the player's rack.
  - Connect popover callback to dispatch tile additions to `GameProvider`.
  - Ensure addition auto-sorts the modified rack/set.
  - Test: Write widget test verifying pressing `+` opens popover and appends the new tiles.
  - Verification: `flutter test Project-Rummikub_frontend/test/tile_addition_integration_test.dart` and `flutter analyze`

## Phase 3: Individual Tile Actions & Quick Clear (Frontend)
- [x] **Task 3.1: Tile Hover Actions Overlay (Edit & Delete)**
  - **Target Files:** `Project-Rummikub_frontend/lib/widgets/tile_widget.dart`, `Project-Rummikub_frontend/lib/widgets/tile_edit_dialog.dart`, `Project-Rummikub_frontend/test/tile_actions_test.dart`
  - Wrap individual tile widget with hover/tap detector showing an action menu with "Edit" and "Delete" buttons.
  - "Delete": Removes the specific tile and triggers auto-sort.
  - "Edit": Opens quick picker dialog/popup to change tile color or value, updating state on confirm.
  - Test: Write widget test verifying edit dialog updates tile value and delete button removes tile.
  - Verification: `flutter test Project-Rummikub_frontend/test/tile_actions_test.dart` and `flutter analyze`

- [x] **Task 3.2: Set and Rack Clear Controls**
  - **Target Files:** `Project-Rummikub_frontend/lib/screens/correction_screen.dart`, `Project-Rummikub_frontend/lib/widgets/rack_widget.dart`, `Project-Rummikub_frontend/test/clear_controls_test.dart`
  - Add a small delete icon above each set on the board. Clicking completely removes the set.
  - Add a clear icon on the rack container. Clicking removes all tiles from the current rack while keeping the rack container intact.
  - Test: Write widget test verifying set deletion removes set from board state, and rack clear empties rack array without destroying rack UI.
  - Verification: `flutter test Project-Rummikub_frontend/test/clear_controls_test.dart` and `flutter analyze`