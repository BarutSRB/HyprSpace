# HyprSpace - User Issues and Feature Requests

This document tracks user-reported issues and feature requests for HyprSpace, categorized by type and with duplicate reports merged.

---

## BUGS

### 1. Centered Bar - Z-Index/Overlap Issues ✅ **[FIXED]**
**Reports: 2 users** | **Priority: HIGH**

**Description:**
The centered workspace bar overlaps the native macOS menu bar, blocking access to menu icons (including HyprSpace itself). Window level settings don't prevent the overlap, which is particularly problematic on narrower MacBook screens.

**User Quotes:**
- "move right of notch works well except it highlights an issue with z-index; the bar is on top of the menu bar, even when I set the window level to menu bar"
- "Spaces Bar overlaps Mac OS Native Menu Bar (on all window level options) which is problematic on not wide MacBook screen"

**Technical Notes:**
- Root cause: All window level options were AT or ABOVE menu bar level
- Fix: Added `.normal` and `.floating` window level options that position bar BELOW menu bar
- Users can now choose between 5 window levels: Normal, Floating, Status Bar, Popup, Screen Saver
- Bar automatically adjusts Y position when using below-menu-bar levels

---

### 2. Centered Bar - Multi-Monitor Display Issues ✅ **[FIXED]**
**Reports: 1 user** | **Priority: MEDIUM**

**Description:**
The centered bar doesn't show on external displays (Studio Display) even when set as primary monitor. Top space is not reserved on the external monitor, and bar only appears on MacBook when focused (in focused mode). Settings don't persist/stick properly.

**User Quote:**
- "whatever I do, the top bar won't show up on the Studio Display which is my primary.. focused mode: bar shows up on MacBook when I focus it. primary; no bar anywhere"

**Technical Notes:**
- Root cause: Single-bar architecture with targetDisplay modes couldn't reliably handle multi-monitor setups
- Fix: Implemented per-monitor bar mode that creates separate bar on each display
- Per-monitor mode automatically detects and adapts to monitor connect/disconnect events

---

### 3. Dwindle Layout - Manual Resize Not Working ❌ **[FIXED]**
**Reports: 2 users** | **Priority: CRITICAL**

**Description:**
Cannot manually resize windows in dwindle layout. Neither mouse dragging nor keyboard shortcuts (alt +/- and alternatives) have any effect. The layout doesn't adopt manual resize changes.

**User Quotes:**
- "manually resizing windows in width or height does not make the dwindle layout adopt it"
- "I can't seem to resize dwindle layout, neither dragging window size or using alt +/- (or using the new suggested combinations)"

**Technical Notes:**
- Root cause: layoutDwindle uses hardcoded 50/50 split ratio
- ResizeCommand and resizeWithMouse correctly update weights
- layoutDwindleRecursive doesn't read node weights
- Fix: Calculate split ratio based on node weights dynamically

---

## FEATURE REQUESTS

### 1. Per-Monitor Bars ✅ **[IMPLEMENTED]**
**Requests: 2 users** | **Priority: HIGH** | **Most Requested Feature**

**Description:**
Display separate centered bar on each monitor, showing only workspaces active on that specific monitor.

**User Quotes:**
- "it would be awesome to have the top bar on each monitor, display only the spaces active on that monitor"
- "Ability to have separate bars with only the workspaces on the current monitor would be a nice to have"

**Implementation:**
- Added "Bar Mode" setting with two options: "Single Bar" and "Per-Monitor Bars"
- Per-monitor mode creates separate bar instance for each connected display
- Each bar shows only workspaces assigned to that monitor (unassigned workspaces appear on primary)
- Automatically handles monitor connect/disconnect with dynamic bar creation/removal
- Both modes coexist for backward compatibility and user preference

---

### 2. Hide Empty Workspaces
**Requests: 1 user** | **Priority: LOW**

**Description:**
Add menu bar option to hide empty workspaces from the centered workspace bar.

**Technical Considerations:**
- Add boolean setting to CenteredBarSettings
- Filter workspace list before rendering
- Update bar when workspace becomes empty/occupied

---

### 3. Notch-Aware Padding
**Requests: 1 user** | **Priority: MEDIUM**

**Description:**
Keep bar centered but add padding around the notch area, allowing the bar to wrap around it elegantly.

**User Quote:**
- "The ideal Notch solution could be to remain centred but to pad the notch area, so that it wraps around it"

**Technical Considerations:**
- Detect notch dimensions via screen safe areas
- Split bar into left/right segments
- Position segments on either side of notch
- Alternative to "move right of notch" approach

---

### 4. Position Below Native Menu Bar
**Requests: 1 user** | **Priority: LOW**

**Description:**
Allow the centered bar to appear underneath the native macOS menu bar, enabling users to auto-hide the native menu bar while keeping the HyprSpace bar visible.

**User Quote:**
- "Please make it possible to appear underneath Menu Bar - in that case we can set the native menu bar to auto hide for instance"

**Technical Considerations:**
- Adjust window level to appear below menu bar
- Calculate Y position offset based on menu bar height
- May conflict with current always-on-top behavior

---

## PRIORITY SUMMARY

### Completed (Fixed/Implemented)
1. ✅ **Dwindle resize bug** - Core functionality broken (FIXED)
2. ✅ **Bar overlaps menu bar** - Blocks access to menu icons (FIXED)
3. ✅ **Per-monitor bars** - Most requested feature, 2 users (IMPLEMENTED)
4. ✅ **Multi-monitor display issues** - Bar not showing on external displays (FIXED via per-monitor mode)

### Medium Priority (Remaining)
5. 💡 **Notch-aware padding** - Better notch integration (wrap around notch)

### Low Priority (Remaining)
6. 📋 **Hide empty workspaces** - QoL improvement
7. 📋 **Position below menu bar** - Alternative positioning option (may be redundant with window level settings)

---

## STATUS LEGEND
- ❌ **Bug** - Broken functionality
- ⚠️ **Usability Issue** - Works but causes problems
- 🌟 **Feature Request** - New functionality
- 💡 **Enhancement** - Improvement to existing feature
- ✅ **Fixed** - Issue resolved

---

*Last Updated: 2025-10-22* (Per-Monitor Bars implemented)
