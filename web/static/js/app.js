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
        this.loadGitHubStars();
    }

    bindEvents() {
        document.getElementById('analyzeBtn').addEventListener('click', () => this.analyzeText());
        document.getElementById('maskBtn').addEventListener('click', () => this.maskText());
        document.getElementById('restoreBtn').addEventListener('click', () => this.restoreText());
        document.getElementById('clearBtn').addEventListener('click', () => this.clearAll());
        document.getElementById('startAnimation').addEventListener('click', () => this.startWorkflowAnimation());
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

    startWorkflowAnimation() {
        const button = document.getElementById('startAnimation');
        const steps = document.querySelectorAll('.workflow-step');
        const arrows = document.querySelectorAll('.workflow-arrow');
        const userText = document.getElementById('userText');
        const firewallText = document.getElementById('firewallText');
        const llmText = document.getElementById('llmText');
        const arrow1 = document.getElementById('arrow1');
        const arrow2 = document.getElementById('arrow2');
        
        // 禁用按钮防止重复点击
        button.disabled = true;
        button.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>动画播放中...';
        
        // 重置所有步骤状态
        steps.forEach(step => {
            step.classList.remove('active', 'completed');
        });
        
        // 重置箭头状态
        arrows.forEach(arrow => {
            arrow.classList.remove('reverse');
        });
        
        // 定义动画序列
        const animationSequence = [
            // 去程阶段
            { step: 0, text: { user: '发送敏感数据', firewall: '匿名化处理', llm: '处理安全数据' }, arrows: { arrow1: 'right', arrow2: 'right' } },
            { step: 1, text: { user: '发送敏感数据', firewall: '匿名化处理', llm: '处理安全数据' }, arrows: { arrow1: 'right', arrow2: 'right' } },
            { step: 2, text: { user: '发送敏感数据', firewall: '匿名化处理', llm: '处理安全数据' }, arrows: { arrow1: 'right', arrow2: 'right' } },
            
            // 回程阶段
            { step: 2, text: { user: '获得安全结果', firewall: '还原隐私数据', llm: '返回处理结果' }, arrows: { arrow1: 'left', arrow2: 'left' } },
            { step: 1, text: { user: '获得安全结果', firewall: '还原隐私数据', llm: '返回处理结果' }, arrows: { arrow1: 'left', arrow2: 'left' } },
            { step: 0, text: { user: '获得安全结果', firewall: '还原隐私数据', llm: '返回处理结果' }, arrows: { arrow1: 'left', arrow2: 'left' } }
        ];
        
        let currentIndex = 0;
        const stepDelay = 1000; // 每个步骤显示1秒
        
        const animateStep = () => {
            if (currentIndex < animationSequence.length) {
                const current = animationSequence[currentIndex];
                
                // 激活当前步骤
                steps[current.step].classList.add('active');
                
                // 更新文字内容
                userText.textContent = current.text.user;
                firewallText.textContent = current.text.firewall;
                llmText.textContent = current.text.llm;
                
                // 更新箭头方向
                if (current.arrows.arrow1 === 'left') {
                    arrow1.classList.add('reverse');
                    arrow1.querySelector('i').className = 'fas fa-arrow-left';
                } else {
                    arrow1.classList.remove('reverse');
                    arrow1.querySelector('i').className = 'fas fa-arrow-right';
                }
                
                if (current.arrows.arrow2 === 'left') {
                    arrow2.classList.add('reverse');
                    arrow2.querySelector('i').className = 'fas fa-arrow-left';
                } else {
                    arrow2.classList.remove('reverse');
                    arrow2.querySelector('i').className = 'fas fa-arrow-right';
                }
                
                currentIndex++;
                
                // 延迟后继续下一步
                setTimeout(() => {
                    if (currentIndex > 1) {
                        steps[current.step].classList.remove('active');
                        steps[current.step].classList.add('completed');
                    }
                    animateStep();
                }, stepDelay);
            } else {
                // 动画完成
                setTimeout(() => {
                    steps[0].classList.remove('active');
                    steps[0].classList.add('completed');
                    
                    // 恢复按钮状态
                    button.disabled = false;
                    button.innerHTML = '<i class="fas fa-play me-2"></i>观看动画演示';
                }, stepDelay);
            }
        };
        
        // 开始动画
        animateStep();
    }

    async loadGitHubStars() {
        const starElement = document.querySelector('.star-count');
        if (!starElement) return;
        
        // 显示加载状态
        starElement.textContent = '...';
        starElement.className = 'star-count loading';
        
        try {
            const response = await fetch('https://api.github.com/repos/funstory-ai/aifw', {
                method: 'GET',
                headers: {
                    'Accept': 'application/vnd.github.v3+json',
                }
            });
            
            if (response.ok) {
                const data = await response.json();
                const starCount = data.stargazers_count;
                
                // 更新显示
                starElement.textContent = starCount;
                starElement.className = 'star-count success';
                starElement.title = `${starCount} stars on GitHub`;
                
                // 添加成功提示
                console.log(`GitHub stars loaded: ${starCount}`);
            } else {
                throw new Error(`GitHub API error: ${response.status}`);
            }
        } catch (error) {
            console.log('GitHub stars not available:', error.message);
            
            // 显示失败状态
            starElement.textContent = '-';
            starElement.className = 'star-count';
            starElement.style.color = '#ccc';
            starElement.title = '无法获取star数量';
        }
    }
}

// 初始化应用
document.addEventListener('DOMContentLoaded', () => {
    new AIFWApp();
});
