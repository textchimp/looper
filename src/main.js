import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import Main from './components/Main.vue'

import './assets/main.css'

const app = createApp(Main)

app.use(createPinia())

app.mount('#app')
