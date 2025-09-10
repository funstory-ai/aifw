// AIFW Web Module JavaScript

class AIFWApp {
    constructor() {
        this.originalText = '';
        this.anonymizedText = '';
        this.placeholdersMap = {};
        this.entities = [];
        this.init();
    }

    init() {
        this.bindEvents();
        this.checkHealth();
    }

    bindEvents() {
        document.getElementById('analyzeBtn').addEventListener('click', () => this.analyzeText());
        document.getElementById('maskBtn').addEventListener('click', () => this.maskText());
        document.getElementById('restoreBtn').addEventListener('click', () => this.restoreText());
        document.getElementById('clearBtn').addEventListener('click', () => this.clearAll());
    }

    async checkHealth() {
        try {
            const response = await fetch('/api/health');
            const data = await response.json();
            if (!data.aifw_available) {
                this.showAlert('warning', 'AIFW 服务不可用，某些功能可能无法使用');
            }
        } catch (error) {
            console.error('Health check failed:', error);
        }
    }

    showAlert(type, message) {
        const alert = document.getElementById('statusAlert');
        const statusText = document.getElementById('statusText');
        statusText.innerHTML = `<i class="fas fa-${type === 'success' ? 'check-circle' : type === 'error' ? 'exclamation-circle' : 'info-circle'} me-2"></i>${message}`;
        alert.className = `alert alert-${type}`;
        alert.style.display = 'block';
        setTimeout(() => {
            alert.style.display = 'none';
        }, 5000);
    }

    showLoading(show) {
        const alert = document.getElementById('statusAlert');
        const statusText = document.getElementById('statusText');
        if (show) {
            statusText.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>处理中...';
            alert.className = 'alert alert-info';
            alert.style.display = 'block';
        } else {
            alert.style.display = 'none';
        }
    }

    async analyzeText() {
        const text = document.getElementById('inputText').value.trim();
        if (!text) {
            this.showAlert('warning', '请输入要分析的文本');
            return;
        }

        this.showLoading(true);
        try {
            const language = document.getElementById('languageSelect').value;
            const response = await fetch('/api/analyze', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ text, language })
            });

            const data = await response.json();
            if (response.ok) {
                this.entities = data.entities;
                this.displayAnalysis(text, data.entities);
                this.showAlert('success', `检测到 ${data.entities.length} 个敏感信息实体`);
            } else {
                this.showAlert('error', data.error || '分析失败');
            }
        } catch (error) {
            this.showAlert('error', '网络错误：' + error.message);
        } finally {
            this.showLoading(false);
        }
    }

    async maskText() {
        const text = document.getElementById('inputText').value.trim();
        if (!text) {
            this.showAlert('warning', '请输入要匿名化的文本');
            return;
        }

        this.showLoading(true);
        try {
            const language = document.getElementById('languageSelect').value;
            const response = await fetch('/api/mask', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ text, language })
            });

            const data = await response.json();
            if (response.ok) {
                this.originalText = data.original_text;
                this.anonymizedText = data.anonymized_text;
                this.placeholdersMap = data.placeholders_map;
                this.displayMasking(data.original_text, data.anonymized_text, data.placeholders_map);
                document.getElementById('restoreBtn').disabled = false;
                this.showAlert('success', '文本匿名化完成');
            } else {
                this.showAlert('error', data.error || '匿名化失败');
            }
        } catch (error) {
            this.showAlert('error', '网络错误：' + error.message);
        } finally {
            this.showLoading(false);
        }
    }

    async restoreText() {
        if (!this.anonymizedText || !this.placeholdersMap) {
            this.showAlert('warning', '没有可恢复的文本');
            return;
        }

        this.showLoading(true);
        try {
            const response = await fetch('/api/restore', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    text: this.anonymizedText,
                    placeholders_map: this.placeholdersMap
                })
            });

            const data = await response.json();
            if (response.ok) {
                this.displayRestoration(data.anonymized_text, data.restored_text);
                this.showAlert('success', '文本恢复完成');
            } else {
                this.showAlert('error', data.error || '恢复失败');
            }
        } catch (error) {
            this.showAlert('error', '网络错误：' + error.message);
        } finally {
            this.showLoading(false);
        }
    }

    displayAnalysis(text, entities) {
        document.getElementById('originalText').textContent = text;
        document.getElementById('processedText').textContent = `检测到 ${entities.length} 个敏感信息实体`;
        
        this.displayEntities(entities);
        document.getElementById('entitiesSection').style.display = 'block';
        document.getElementById('placeholdersSection').style.display = 'none';
    }

    displayMasking(original, anonymized, placeholders) {
        document.getElementById('originalText').textContent = original;
        document.getElementById('processedText').textContent = anonymized;
        
        this.displayPlaceholders(placeholders);
        document.getElementById('entitiesSection').style.display = 'none';
        document.getElementById('placeholdersSection').style.display = 'block';
    }

    displayRestoration(anonymized, restored) {
        document.getElementById('originalText').textContent = anonymized;
        document.getElementById('processedText').textContent = restored;
    }

    displayEntities(entities) {
        const tbody = document.getElementById('entitiesTable');
        tbody.innerHTML = '';
        
        entities.forEach(entity => {
            const row = tbody.insertRow();
            row.insertCell(0).textContent = this.getEntityTypeName(entity.entity_type);
            row.insertCell(1).textContent = entity.text;
            row.insertCell(2).textContent = `${entity.start}-${entity.end}`;
            row.insertCell(3).textContent = (entity.score * 100).toFixed(1) + '%';
            
            // 添加类型样式
            const typeCell = row.cells[0];
            typeCell.className = `entity-${entity.entity_type.toLowerCase().replace('_', '-')}`;
        });
    }

    displayPlaceholders(placeholders) {
        const tbody = document.getElementById('placeholdersTable');
        tbody.innerHTML = '';
        
        Object.entries(placeholders).forEach(([placeholder, original]) => {
            const row = tbody.insertRow();
            row.insertCell(0).textContent = placeholder;
            row.insertCell(1).textContent = original;
        });
    }

    getEntityTypeName(type) {
        const typeMap = {
            'EMAIL_ADDRESS': '邮箱地址',
            'PHONE_NUMBER': '电话号码',
            'CREDIT_CARD': '信用卡号',
            'PERSON': '人名',
            'LOCATION': '地址',
            'IBAN_CODE': '银行账户',
            'IP_ADDRESS': 'IP地址',
            'URL': '网址',
            'DATE_TIME': '日期时间',
            'US_SSN': '社会安全号',
            'US_PASSPORT': '护照号',
            'US_DRIVER_LICENSE': '驾驶证号'
        };
        return typeMap[type] || type;
    }

    clearAll() {
        document.getElementById('inputText').value = '';
        document.getElementById('originalText').textContent = '点击"分析敏感信息"或"匿名化处理"按钮开始...';
        document.getElementById('processedText').textContent = '处理结果将显示在这里...';
        document.getElementById('restoreBtn').disabled = true;
        document.getElementById('entitiesSection').style.display = 'none';
        document.getElementById('placeholdersSection').style.display = 'none';
        this.originalText = '';
        this.anonymizedText = '';
        this.placeholdersMap = {};
        this.entities = [];
    }
}

// 初始化应用
document.addEventListener('DOMContentLoaded', () => {
    new AIFWApp();
});
