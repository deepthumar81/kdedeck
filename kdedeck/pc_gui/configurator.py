import os
import sys
import json
import socket
import subprocess
import customtkinter as ctk

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

from kdedeck.server.config_manager import ConfigManager
from kdedeck.server.app_scanner import AppScanner

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

class KdeDeckConfiguratorApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        self.title("KdeDeck v1.0 - PC Desktop Configurator")
        self.geometry("960 x 680")
        self.minsize(840, 600)

        self.config_mgr = ConfigManager()
        self.config_data = self.config_mgr.get_config()
        self.active_board_idx = 0
        self.selected_item_idx = None
        self.installed_apps = AppScanner.get_installed_apps()

        self.build_ui()

    def get_local_ip(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return "127.0.0.1"

    def build_ui(self):
        # Top Header Bar
        self.header_frame = ctk.CTkFrame(self, height=60, corner_radius=0, fg_color="#0f172a")
        self.header_frame.pack(fill="x", side="top")

        self.logo_label = ctk.CTkLabel(
            self.header_frame, 
            text="⚡ KDE DECK CONFIGURATOR (v1.0)", 
            font=ctk.CTkFont(size=18, weight="bold"),
            text_color="#38bdf8"
        )
        self.logo_label.pack(side="left", padx=20, pady=15)

        local_ip = self.get_local_ip()
        port = self.config_data.get("port", 8484)
        pin = self.config_data.get("pin", "8484")
        
        self.conn_info_label = ctk.CTkLabel(
            self.header_frame,
            text=f"📱 Phone Link: http://{local_ip}:{port}  |  PIN: {pin}",
            font=ctk.CTkFont(size=13, weight="bold"),
            text_color="#4ade80"
        )
        self.conn_info_label.pack(side="right", padx=20, pady=15)

        # Main Layout (Left Sidebar + Right Editor Workspace)
        self.main_body = ctk.CTkFrame(self, fg_color="transparent")
        self.main_body.pack(fill="both", expand=True, padx=15, pady=15)

        # Left Sidebar (Board Navigation & Global Settings)
        self.sidebar = ctk.CTkFrame(self.main_body, width=240, corner_radius=16, fg_color="#1e293b")
        self.sidebar.pack(side="left", fill="y", padx=(0, 10))

        self.boards_header = ctk.CTkLabel(
            self.sidebar, 
            text="DECKS & BOARDS", 
            font=ctk.CTkFont(size=14, weight="bold"),
            text_color="#94a3b8"
        )
        self.boards_header.pack(anchor="w", padx=16, pady=(16, 8))

        self.board_list_scroll = ctk.CTkScrollableFrame(self.sidebar, fg_color="transparent")
        self.board_list_scroll.pack(fill="both", expand=True, padx=8, pady=4)

        self.add_board_btn = ctk.CTkButton(
            self.sidebar,
            text="+ Create New Deck",
            fg_color="#0284c7",
            hover_color="#0369a1",
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self.create_new_board
        )
        self.add_board_btn.pack(fill="x", padx=12, pady=10)

        # Global Matrix Grid Size Settings
        self.grid_settings_frame = ctk.CTkFrame(self.sidebar, fg_color="transparent")
        self.grid_settings_frame.pack(fill="x", padx=12, pady=(0, 16))

        self.grid_title = ctk.CTkLabel(
            self.grid_settings_frame, 
            text="MATRIX GRID SIZE", 
            font=ctk.CTkFont(size=12, weight="bold"),
            text_color="#94a3b8"
        )
        self.grid_title.pack(anchor="w", pady=(4, 4))

        self.grid_cols_entry = ctk.CTkOptionMenu(
            self.grid_settings_frame,
            values=["3 Cols", "4 Cols", "5 Cols", "6 Cols", "8 Cols"],
            command=self.on_grid_cols_changed
        )
        curr_cols = self.config_data.get("grid_columns", 4)
        self.grid_cols_entry.set(f"{curr_cols} Cols")
        self.grid_cols_entry.pack(fill="x", pady=4)

        self.grid_rows_entry = ctk.CTkOptionMenu(
            self.grid_settings_frame,
            values=["3 Rows", "4 Rows", "5 Rows", "6 Rows", "7 Rows", "8 Rows"],
            command=self.on_grid_rows_changed
        )
        curr_rows = self.config_data.get("grid_rows", 3)
        self.grid_rows_entry.set(f"{curr_rows} Rows")
        self.grid_rows_entry.pack(fill="x", pady=4)

        # Right Workspace (Item Editor & Matrix Grid Preview)
        self.workspace = ctk.CTkFrame(self.main_body, corner_radius=16, fg_color="#1e293b")
        self.workspace.pack(side="right", fill="both", expand=True)

        self.workspace_header = ctk.CTkFrame(self.workspace, height=45, fg_color="transparent")
        self.workspace_header.pack(fill="x", padx=16, pady=12)

        self.board_title_label = ctk.CTkLabel(
            self.workspace_header, 
            text="Deck Items Matrix Preview", 
            font=ctk.CTkFont(size=16, weight="bold")
        )
        self.board_title_label.pack(side="left")

        self.save_btn = ctk.CTkButton(
            self.workspace_header,
            text="💾 Save All Changes",
            fg_color="#16a34a",
            hover_color="#15803d",
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self.save_config
        )
        self.save_btn.pack(side="right", padx=5)

        self.add_item_btn = ctk.CTkButton(
            self.workspace_header,
            text="+ Add Button Item",
            fg_color="#2563eb",
            hover_color="#1d4ed8",
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self.create_new_item
        )
        self.add_item_btn.pack(side="right", padx=5)

        # Grid Workspace Matrix Preview
        self.grid_preview_frame = ctk.CTkScrollableFrame(self.workspace, fg_color="#0f172a", corner_radius=12)
        self.grid_preview_frame.pack(fill="both", expand=True, padx=16, pady=(0, 16))

        self.render_sidebar_boards()
        self.render_workspace_grid()

    def render_sidebar_boards(self):
        for widget in self.board_list_scroll.winfo_children():
            widget.destroy()

        boards = self.config_data.get("boards", [])
        for idx, board in enumerate(boards):
            is_active = idx == self.active_board_idx
            btn = ctk.CTkButton(
                self.board_list_scroll,
                text=f"📋 {board.get('title', 'Board')}",
                fg_color="#3b82f6" if is_active else "transparent",
                hover_color="#2563eb" if is_active else "#334155",
                anchor="w",
                font=ctk.CTkFont(size=13, weight="bold" if is_active else "normal"),
                command=lambda i=idx: self.select_board(i)
            )
            btn.pack(fill="x", pady=3)

    def select_board(self, idx):
        self.active_board_idx = idx
        self.render_sidebar_boards()
        self.render_workspace_grid()

    def render_workspace_grid(self):
        for widget in self.grid_preview_frame.winfo_children():
            widget.destroy()

        boards = self.config_data.get("boards", [])
        if not boards or self.active_board_idx >= len(boards):
            return

        board = boards[self.active_board_idx]
        self.board_title_label.configure(text=f"Deck: {board.get('title', 'Board')}")

        items = board.get("items", [])
        cols = self.config_data.get("grid_columns", 4)

        for item_idx, item in enumerate(items):
            r = item_idx // cols
            c = item_idx % cols

            item_card = ctk.CTkFrame(
                self.grid_preview_frame, 
                width=130, 
                height=110, 
                corner_radius=12,
                fg_color="#1e293b",
                border_width=2,
                border_color=self.get_color_hex(item.get("color", "neon-cyan"))
            )
            item_card.grid(row=r, column=c, padx=8, pady=8, sticky="nsew")

            title_lbl = ctk.CTkLabel(
                item_card, 
                text=item.get("title", "Button"), 
                font=ctk.CTkFont(size=12, weight="bold"),
                wraplength=110
            )
            title_lbl.pack(pady=(12, 4))

            action_lbl = ctk.CTkLabel(
                item_card, 
                text=item.get("action", "launch_app"), 
                font=ctk.CTkFont(size=10),
                text_color="#94a3b8"
            )
            action_lbl.pack(pady=2)

            edit_btn = ctk.CTkButton(
                item_card,
                text="Edit",
                width=60,
                height=24,
                font=ctk.CTkFont(size=11),
                fg_color="#334155",
                hover_color="#475569",
                command=lambda i=item_idx: self.open_item_editor(i)
            )
            edit_btn.pack(pady=(6, 8))

    def get_color_hex(self, name):
        colors = {
            "neon-green": "#22c55e",
            "neon-blue": "#3b82f6",
            "neon-cyan": "#06b6d4",
            "neon-purple": "#a855f7",
            "neon-pink": "#ec4899",
            "neon-amber": "#f59e0b",
            "neon-red": "#ef4444",
            "neon-orange": "#f97316",
            "neon-yellow": "#eab308",
            "neon-slate": "#64748b"
        }
        return colors.get(name, "#06b6d4")

    def on_grid_cols_changed(self, val):
        cols = int(val.split()[0])
        self.config_data["grid_columns"] = cols
        self.render_workspace_grid()

    def on_grid_rows_changed(self, val):
        rows = int(val.split()[0])
        self.config_data["grid_rows"] = rows
        self.render_workspace_grid()

    def create_new_board(self):
        boards = self.config_data.get("boards", [])
        new_board = {
            "id": f"board_{int(os.urandom(4).hex(), 16)}",
            "title": f"Board {len(boards) + 1}",
            "icon": "layers",
            "items": []
        }
        boards.append(new_board)
        self.active_board_idx = len(boards) - 1
        self.render_sidebar_boards()
        self.render_workspace_grid()

    def create_new_item(self):
        boards = self.config_data.get("boards", [])
        if not boards:
            return
        items = boards[self.active_board_idx].get("items", [])
        new_item = {
            "type": "button",
            "id": f"item_{int(os.urandom(4).hex(), 16)}",
            "title": "New Application",
            "action": "launch_app",
            "payload": "konsole",
            "icon": "terminal",
            "color": "neon-cyan"
        }
        items.append(new_item)
        self.render_workspace_grid()
        self.open_item_editor(len(items) - 1)

    def open_item_editor(self, item_idx):
        boards = self.config_data.get("boards", [])
        item = boards[self.active_board_idx]["items"][item_idx]

        editor = ctk.CTkToplevel(self)
        editor.title(f"Edit Item: {item.get('title')}")
        editor.geometry("460 x 520")
        editor.attributes("-topmost", True)

        ctk.CTkLabel(editor, text="Edit Button Configuration", font=ctk.CTkFont(size=16, weight="bold")).pack(pady=15)

        # Installed App Picker
        ctk.CTkLabel(editor, text="Pick Installed App (APT / Flatpak / Snap)", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        app_names = [f"{a['name']} ({a['exec']})" for a in self.installed_apps]
        app_picker = ctk.CTkOptionMenu(editor, values=["-- Pick Installed App --"] + app_names)
        app_picker.pack(fill="x", padx=20, pady=(2, 10))

        def on_app_pick(choice):
            for a in self.installed_apps:
                if f"{a['name']} ({a['exec']})" == choice:
                    title_entry.delete(0, "end")
                    title_entry.insert(0, a["name"])
                    payload_entry.delete(0, "end")
                    payload_entry.insert(0, a["exec"])
                    icon_entry.delete(0, "end")
                    icon_entry.insert(0, a["icon"])
                    action_picker.set("launch_app")
                    break

        app_picker.configure(command=on_app_pick)

        # Button Label
        ctk.CTkLabel(editor, text="Button Label", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        title_entry = ctk.CTkEntry(editor)
        title_entry.insert(0, item.get("title", ""))
        title_entry.pack(fill="x", padx=20, pady=(2, 10))

        # Action Type
        ctk.CTkLabel(editor, text="Action Type", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        actions = ["launch_app", "open_url", "audio_volume", "brightness", "audio_mute_toggle", "mpris_action", "kdeconnect_ring", "kde_action"]
        action_picker = ctk.CTkOptionMenu(editor, values=actions)
        action_picker.set(item.get("action", "launch_app"))
        action_picker.pack(fill="x", padx=20, pady=(2, 10))

        # Payload
        ctk.CTkLabel(editor, text="Payload (App Binary / URL / Command)", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        payload_entry = ctk.CTkEntry(editor)
        payload_entry.insert(0, item.get("payload", ""))
        payload_entry.pack(fill="x", padx=20, pady=(2, 10))

        # Icon Name
        ctk.CTkLabel(editor, text="Icon Name (App Icon / Lucide Name)", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        icon_entry = ctk.CTkEntry(editor)
        icon_entry.insert(0, item.get("icon", "terminal"))
        icon_entry.pack(fill="x", padx=20, pady=(2, 10))

        # Neon Color Accent
        ctk.CTkLabel(editor, text="Neon Color Accent", font=ctk.CTkFont(size=12, weight="bold")).pack(anchor="w", padx=20)
        color_picker = ctk.CTkOptionMenu(editor, values=["neon-cyan", "neon-green", "neon-blue", "neon-purple", "neon-pink", "neon-amber", "neon-red", "neon-orange", "neon-yellow"])
        color_picker.set(item.get("color", "neon-cyan"))
        color_picker.pack(fill="x", padx=20, pady=(2, 16))

        def save_item():
            item["title"] = title_entry.get()
            item["action"] = action_picker.get()
            item["payload"] = payload_entry.get()
            item["icon"] = icon_entry.get()
            item["color"] = color_picker.get()
            self.render_workspace_grid()
            editor.destroy()

        def delete_item():
            boards[self.active_board_idx]["items"].pop(item_idx)
            self.render_workspace_grid()
            editor.destroy()

        btn_frame = ctk.CTkFrame(editor, fg_color="transparent")
        btn_frame.pack(fill="x", padx=20, pady=10)

        ctk.CTkButton(btn_frame, text="Delete Item", fg_color="#ef4444", hover_color="#dc2626", command=delete_item).pack(side="left")
        ctk.CTkButton(btn_frame, text="Save Item Changes", fg_color="#16a34a", hover_color="#15803d", command=save_item).pack(side="right")

    def save_config(self):
        self.config_mgr.save_config(self.config_data)
        subprocess.run(["pkill", "-HUP", "-f", "kdedeck/server/main.py"], check=False)
        self.conn_info_label.configure(text=f"✅ Saved & Reloaded | Phone Link: http://{self.get_local_ip()}:{self.config_data.get('port', 8484)}")

def main():
    app = KdeDeckConfiguratorApp()
    app.mainloop()

if __name__ == "__main__":
    main()
