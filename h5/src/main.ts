import { createApp } from 'vue'
import App from './App.vue'
import { loadLastSync, runSync } from './core/app'
import router from './router'
import './style.css'

createApp(App).use(router).mount('#app')

void loadLastSync()
// Sync on start; offline just shows a message and the local data keeps working.
void runSync()
window.addEventListener('online', () => void runSync())
