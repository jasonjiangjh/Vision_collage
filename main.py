import os
import sys
import time
import requests
from PIL import Image
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                            QHBoxLayout, QLabel, QPushButton, QGridLayout,
                            QScrollArea)
from PyQt5.QtCore import Qt, QTimer, QEvent, QThread, pyqtSignal
from PyQt5.QtGui import QPixmap, QColor, QPainter

class ImageLoader(QThread):
    """改进的异步图片加载线程"""
    loaded = pyqtSignal(QLabel, QPixmap, str)
    error = pyqtSignal(str)

    def __init__(self, label, url):
        super().__init__()
        self.label = label
        self.url = url
        self._is_running = True

    def run(self):
        try:
            if not self._is_running:
                return
                
            response = requests.get(self.url, timeout=10)
            response.raise_for_status()
            
            pixmap = QPixmap()
            if pixmap.loadFromData(response.content) and self._is_running:
                self.loaded.emit(self.label, pixmap, self.url)
            else:
                self.error.emit(f"无效的图片数据: {self.url}")
                
        except Exception as e:
            self.error.emit(f"加载失败: {self.url} - {str(e)}")
            
    def stop(self):
        self._is_running = False
        self.quit()
        self.wait(1000)

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("心理疗愈壁纸")
        self.setMinimumSize(400, 700)
        
        # 初始化组件
        self.scroll = QScrollArea()
        self.container = QWidget()
        self.grid = QGridLayout(self.container)
        self.selected_images = []
        self.excluded_urls = []
        self.current_page = 1
        self.loaders = []
        self.current_batch = []
        
        # 初始化界面
        self.init_ui()
        self.load_new_batch()
        
        # 壁纸定时器
        self.wallpaper_timer = QTimer()
        self.wallpaper_timer.timeout.connect(self.update_wallpaper)
        
        # 安装事件过滤器
        self.scroll.viewport().installEventFilter(self)

    def init_ui(self):
        main_widget = QWidget()
        layout = QVBoxLayout(main_widget)
        
        # 滚动区域设置
        self.scroll.setWidgetResizable(True)
        self.scroll.setWidget(self.container)
        self.grid.setSpacing(15)
        self.grid.setContentsMargins(15, 15, 15, 15)
        
        # 控制按钮
        control_box = QHBoxLayout()
        
        self.btn_refresh = QPushButton("换一批", self)
        self.btn_refresh.setStyleSheet("""
            QPushButton {
                background: #2196F3;
                color: white;
                padding: 12px;
                border-radius: 6px;
                font-size: 16px;
            }
        """)
        self.btn_refresh.clicked.connect(self.load_new_batch)
        
        self.btn_generate = QPushButton("生成壁纸", self)
        self.btn_generate.setStyleSheet("""
            QPushButton {
                background: #4CAF50;
                color: white;
                padding: 12px;
                border-radius: 6px;
                font-size: 16px;
            }
            QPushButton:disabled {
                background: #81C784;
            }
        """)
        self.btn_generate.clicked.connect(self.generate_wallpaper)
        
        control_box.addWidget(self.btn_refresh)
        control_box.addStretch()
        control_box.addWidget(self.btn_generate)
        
        layout.addWidget(self.scroll)
        layout.addLayout(control_box)
        self.setCentralWidget(main_widget)

    def closeEvent(self, event):
        """窗口关闭时停止所有线程"""
        for loader in self.loaders:
            loader.stop()
        event.accept()

    def eventFilter(self, obj, event):
        """实现下滑加载更多"""
        if event.type() == QEvent.MouseMove:
            scroll_bar = self.scroll.verticalScrollBar()
            if scroll_bar.value() == scroll_bar.maximum():
                self.load_more_images()
        return super().eventFilter(obj, event)

    def load_new_batch(self):
        """加载全新批次图片"""
        self.clear_current_batch()
        self.current_page = int(time.time() % 100)  # 随机页码
        self.load_images()

    def clear_current_batch(self):
        """清空当前批次内容"""
        for loader in self.loaders:
            loader.stop()
        self.loaders.clear()
        
        while self.grid.count():
            item = self.grid.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()
        
        self.current_batch.clear()

    def load_more_images(self):
        """加载更多图片（分页）"""
        self.current_page += 1
        self.load_images()

    def load_images(self):
        """图片加载核心方法"""
        try:
            response = requests.get(
                f"https://picsum.photos/v2/list?page={self.current_page}&limit=9&order_by=random",
                timeout=10
            )
            image_data = response.json()
            image_urls = [item["download_url"] for item in image_data]
            self.current_batch = image_urls.copy()
            
        except Exception as e:
            self.show_message(f"图片加载失败: {str(e)}", 3000)
            return
        
        for i, url in enumerate(image_urls):
            self.add_image_thumbnail(url, i)

    def add_image_thumbnail(self, url, position):
        """创建图片缩略图"""
        thumbnail = QLabel()
        thumbnail.url = url
        thumbnail.setFixedSize(200, 200)
        thumbnail.setAlignment(Qt.AlignCenter)
        thumbnail.setStyleSheet("""
            border: 2px solid #BDBDBD;
            border-radius: 8px;
            background: #F5F5F5;
        """)
        
        # 生成程序内占位图
        placeholder = QPixmap(200, 200)
        placeholder.fill(QColor(245, 245, 245))
        painter = QPainter(placeholder)
        painter.setPen(QColor(189, 189, 189))
        painter.drawText(placeholder.rect(), Qt.AlignCenter, "加载中...")
        painter.end()
        thumbnail.setPixmap(placeholder)
        
        # 启动异步加载
        loader = ImageLoader(thumbnail, url)
        loader.loaded.connect(self.on_image_loaded)
        loader.error.connect(lambda msg: print(msg))
        self.loaders.append(loader)
        loader.start()
        
        # 添加点击事件
        thumbnail.mousePressEvent = lambda e, u=url: self.toggle_selection(u)
        self.grid.addWidget(thumbnail, position//3, position%3)

    def on_image_loaded(self, label, pixmap, url):
        """图片加载完成回调"""
        if label.url == url and not pixmap.isNull():
            label.setPixmap(pixmap.scaled(
                200, 200, 
                Qt.KeepAspectRatioByExpanding, 
                Qt.SmoothTransformation
            ))

    def toggle_selection(self, url):
        """处理图片选择/排除"""
        if url in self.excluded_urls:
            return
            
        if url in self.selected_images:
            self.selected_images.remove(url)
        else:
            if len(self.selected_images) >= 10:
                self.show_message("最多选择10张图片", 2000)
                return
            self.selected_images.append(url)
        
        self.update_selection_ui(url)
        self.btn_generate.setEnabled(len(self.selected_images) > 0)

    def update_selection_ui(self, url):
        """更新选中状态的可视化"""
        for i in range(self.grid.count()):
            widget = self.grid.itemAt(i).widget()
            if widget and hasattr(widget, 'url') and widget.url == url:
                if url in self.selected_images:
                    widget.setStyleSheet("border: 3px solid #4CAF50;")
                else:
                    widget.setStyleSheet("border: 2px solid #BDBDBD;")
                break
            
    def generate_wallpaper(self):
        """生成壁纸入口"""
        self.show_message("壁纸生成中...", 2000)
        
        if len(self.selected_images) == 1:
            self.set_single_wallpaper(self.selected_images[0])
        else:
            self.create_collage(self.selected_images)
            
        self.wallpaper_timer.start(3600000)  # 1小时

    def set_single_wallpaper(self, url):
        """设置单图壁纸"""
        try:
            response = requests.get(url, stream=True, timeout=20)
            img = Image.open(response.raw)
            img.save("current_wallpaper.jpg")
            self.set_system_wallpaper("current_wallpaper.jpg")
            self.show_message("壁纸设置成功", 2000)
        except Exception as e:
            self.show_message(f"壁纸设置失败: {str(e)}", 3000)

    def create_collage(self, urls):
        """创建拼图壁纸"""
        try:
            collage = Image.new('RGB', (1920, 1080))  # 适应常见屏幕尺寸
            for index, url in enumerate(urls[:9]):
                response = requests.get(url, stream=True, timeout=20)
                img = Image.open(response.raw)
                img.thumbnail((640, 360))
                collage.paste(img, (640*(index%3), 360*(index//3)))
                
            collage.save("wallpaper_collage.jpg")
            self.set_system_wallpaper("wallpaper_collage.jpg")
            self.show_message("拼图壁纸已生成", 2000)
        except Exception as e:
            self.show_message(f"拼图生成失败: {str(e)}", 3000)

    def set_system_wallpaper(self, path):
        """系统壁纸设置（跨平台实现）"""
        try:
            path = os.path.abspath(path)
            if sys.platform == "linux":
                os.system(f"gsettings set org.gnome.desktop.background picture-uri file://{path}")
            elif sys.platform == "win32":
                import ctypes
                ctypes.windll.user32.SystemParametersInfoW(20, 0, path, 3)
            elif sys.platform == "darwin":
                os.system(f"""
                    osascript -e 'tell application "Finder" to set desktop picture to POSIX file "{path}"'
                """)
        except Exception as e:
            self.show_message(f"系统壁纸设置失败: {str(e)}", 3000)

    def update_wallpaper(self):
        """定时更新壁纸"""
        if self.selected_images:
            self.generate_wallpaper()

    def show_message(self, text, duration=3000):
        """显示临时提示信息"""
        msg = QLabel(text, self)
        msg.setAlignment(Qt.AlignCenter)
        msg.setStyleSheet("""
            background: #4CAF50;
            color: white;
            padding: 12px 24px;
            border-radius: 8px;
            font-size: 14px;
            min-width: 200px;
        """)
        msg.adjustSize()
        msg.move(self.width()//2 - msg.width()//2, 20)
        msg.show()
        
        QTimer.singleShot(duration, msg.hide)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())