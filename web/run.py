#!/usr/bin/env python3
"""
AIFW Web Module Runner
启动 AIFW Web 模块的脚本
"""

import os
import sys

def main():
    print("=== AIFW Web Module ===")
    print("正在启动 AIFW Web 模块...")
    
    # 检查是否在正确的目录
    if not os.path.exists('app.py'):
        print("错误：请在 web 目录下运行此脚本")
        sys.exit(1)
    
    # 检查依赖
    # 启动应用
    print("\n启动 Web 服务器...")
    print("访问地址: http://localhost:5001")
    print("按 Ctrl+C 停止服务器")
    print("-" * 50)
    
    try:
        from app import app
        app.run(debug=True, host='0.0.0.0', port=5001)
    except KeyboardInterrupt:
        print("\n服务器已停止")
    except Exception as e:
        print(f"启动失败: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
