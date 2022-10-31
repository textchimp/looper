<template>
  <div class="container">

    <div v-if="testMode" class="27-10-22_10.49.28pm.full.wavWarn">TEST MODE</div>

    <div id="inputDevices">
      <span class="label">
        In: {{ this.selectedInputDeviceNameAbbrev }}
      </span>
      <span class="select">
        <select 
          v-model="selectedInputDevice" 
          @change="inputChanged" 
          @keydown.space.prevent="handleSpacebarPress"
        >
          <option :key="id" v-for="(name, id) in audioDevices" :value="id">In: {{ name }}</option>
        </select>  
        <label>
          <input type="checkbox" 
            v-model="inputIsMono" 
            @change="monoChanged" 
            @keydown.space.prevent="handleSpacebarPress"
          />Mono</label>
      </span>
    </div>

     <div id="outputDevices"  @click="setOutputDevice" :title="selectedOutputDevice.label">
        <span>Out</span>
     </div>

    <div id="msg">
              
      <div v-if="isRecording">[ recording ]</div>
      <div v-else-if="isWaitingToRecord">[ record arm: {{recordThreshold}} ]</div>

      <div v-if="!isRecording && hasEverRecorded" @click.stop="" class="rangeResetArea">

        <div id="controls">
          <!-- <input @click.stop="" type="range" min="0" max="20000" v-model="lowpassFilterFreq"> -->
          <Slider v-model="lowpassFilterFreq"
            label="gain" :min="0" :max="4" :defaultValue="1" 
            style="height: 30px; width: 400px; margin: 0 auto;" 
          />
          <Slider v-model="playbackRate"
            label="rate" :min="0.13" :max="2" :defaultValue="1" 
            style="height: 30px; width: 400px; margin: 0 auto;" 
          />
          <Slider v-model="stereoPan"
            label="pan" :min="-1" :max="1" :defaultValue="0" 
            style="height: 30px; width: 400px; margin: 0 auto;" 
          />
        </div><!-- #controls -->

      </div><!-- .rangeResetArea -->
    </div> 

    <div id="micMonitor" ref="micMonitor" 
      :class="((monitorOnStart || isRecording || isWaitingToRecord) && !testMode) && 'recording'"
    ></div>

    <Wave 
      ref="wavePlayer"
      @stateChange="playerStateChange"
      :inputDeviceId="selectedInputDevice"
      :channelCount="channelCount"
      :class="isRecording && 'recording'"
    />
    <!-- :state="waveState" -->
    <!-- :action="waveAction" -->
    

  <div id="instructions" v-if="isProduction">
    [<strong>tab</strong>]: record toggle, 
    [<strong>space</strong>]: play toggle,
    [<strong>s</strong>]: save to file,
    [<strong>,  .  / </strong>]: slower/faster/reset,
    [<strong>drag</strong>]: create/adjust loop region,

  </div>

  </div>
</template>


<script>


const MIN_ZOOM_LEVEL = 160;
const MAX_ZOOM_LEVEL = 500;
const WAVE_HEIGHT_FACTOR = 0.85;

const REGION_RESIZE_SMALL = 0.01;
const REGION_RESIZE_MEDIUM = 0.1;
const REGION_RESIZE_LARGE = 0.2;

let chunks = [];

const env = process.env.NODE_ENV;

/*
TODO:


  - 1. save regions ffs... fucking STILL not working consistently - WAIT has changing the Blob type to 'audio/wav' fixed it?
    - OfflineAudioContext? https://stackoverflow.com/a/66799384
    - wavesurfer.exportPCM (JSON) accepts range, then back to data?


  - 2. x2,3,..8 region range dup

  - extract to components: <Wave>, <Monitor> ... state callbacks? just $emit?



  - show timestamp on region handle drag, cursor click, etc

  - for drag-dropped/pasted file, get correct channel count and set inputIsMono

  - highlight waveform handle temporarily when adjusting using keyboard

  - Cloudinary upload / load?

  - how to handle overlapping/nested regions? causes weird loop behaviour, can't select when obscured completely, etc

  - arrow icons/unicode for drag handles

  - Cmd+v to paste URL to load? WORKS, but no visible waveform unless CORS allowed - try loading into hidden <audio> tag first to get around CORS?

  - show friendly message/instructions if mic permission not given

  - sort out damn play/pause/loop of regions inconsistencies

  - prevent leaving region on scroll
  - scroll to zoom weird behaviour - THROTTLE to prevent it choking the CPU

  - middle click to extend region? 'auxclick' event! (what about trackpad though?)

  NOTE: Device labels will only be shown is MediaStream is already active
  OR 'persistent permissions' have already been granted

  NOTE: Firefox config 'media.setsinkid.enabled' required to be set to 'true' to allow list of output devicess
*/

function d(...args){
  let callerName;
  try { throw new Error(); }
  catch (e) { 
      // var re = /(\w+)@|at (\w+) \(/g, st = e.stack, m;
      // re.exec(st), m = re.exec(st);
      // callerName = m[1] || m[2];
      // console.log('stack', e.stack);
      // console.dir(e.stack.split('\n'));
      callerName = e.stack.split('\n')[1].split('@')[0]
      callerName = callerName.split('/')[0];
  }
  console.log('%ccaller: %s()', 'font-size: 11pt;', callerName);
  console.log(...args);
} // d()

import WaveSurfer from 'wavesurfer.js';
import MicrophonePlugin from 'wavesurfer.js/dist/plugin/wavesurfer.microphone.min.js';

// import {useWavePlayerStore} from '@/stores/wavePlayer.js';

// import VueSlideBar from 'vue-slide-bar';
import Slider from './ui/Slider.vue';
import Wave from './Wave.vue';


// Keep these out of state?
let wavesurfer = null;
let wavesurferMicMonitor = null;
let mediaRecorder = null;

const filters = {
};


 export default {
  name: 'Main',
  components: { Slider, Wave },
  
  data(){
    return {
      // STATE
      playbackRate: 1.0,
      zoomLevel: MIN_ZOOM_LEVEL,
      regionIsLooping: false,
      isRecording: false,
      isWaitingToRecord: false,
      monitorOnStart: true,
      recordThreshold: 0.1,
      hasEverRecorded: false,
      recordClass: '',
      lastRegion: null,
      regionCount: 0,

      lowpassFilterFreq: 0,
      stereoPan: 0, 

      // <Wave> props
      channelCount: 2,
      waveState: 'stopped',
      waveAction: null,
      // waveLoad: null,

      // waveStore: useWavePlayerStore(), // TODO: should the store ref be kept in state?

      showSplashScreen: true,

      audioDevices: {},
      prevAudioDevices: {}, // for keeping track of added device
      selectedInputDevice: null,
      selectedOutputDevice: {},
      inputIsMono: false,

      testMode: false,

      keysHeld: {
        Control: false,
        Alt: false,
        Meta: false,
        Shift: false,
      },

      isProduction: env !== 'development',
    };
  },


  computed: {

    recordingStatus(){
      return this.isRecording ? 'Recording...' : '';
    },

    selectedInputDeviceName(){
      return this.audioDevices[this.selectedInputDevice] || '(none)';
    },

    selectedInputDeviceNameAbbrev(){
      const name = this.audioDevices[this.selectedInputDevice];
      if(!name) return '(none)';
      const abbrev = name.split(' ').slice(0, 2).map(s => s.substring(0, 3)).join('');
      const mono = this.inputIsMono ? ' (mono)' : '';
      return abbrev + mono;
    },

    getMicMonitorStyle(){
      // can't just use 'v-if' because mic plugin needs to find container element or throws
      return this.isRecording ? 'display: inline-block' : 'display: none' ;
    },

    getWaveformStyle(){
      return this.isRecording ? 'display: none' : 'display: inline-block' ;
    },

  },


  watch: {
    
    playbackRate(v){
      if( v > 0.13 && v < 2.7 ){
        wavesurfer.setPlaybackRate(Number(v));
      } 
    },

    lowpassFilterFreq(v){
      console.log('lowpass', v);
      // l.frequency.value = v;
      g.gain.value = v;
    },

    stereoPan(v){
      filters.panner.pan.value = v;
      d(v);
    },

    // NO! Watchers are async, which is too hard to debug
    // So instead: manually run this.initRecorder() after change to input
    // selectedInputDevice(v){
    //   console.log('%cWATCHER: selectedInputDevice', 'color: blue');
    //   this.initRecorder(); // re-initialise audio input
    // },

  }, // watch


  filters: {
    // WHY DOESN'T THIS WORK
    nameAbbrevfunction(str){
      return str.split(' ').map(s => s[0]).join('');
    },

  },


  mounted(){

    this.restoreState();

    this.getMediaDevices();
      // triggers:
      // this.initRecorder(); 
      // this.initMicMonitor();
      //
      // .... if devices are available

    navigator.mediaDevices.ondevicechange = (e) => {
      this.getMediaDevices(true); // arg indicates change, not init
    };

    // this.initFileDragDrop();
    // this.initWavesurfer();

    this.initKeyHandlers();

    // Enable test mode from ?test= param
    this.checkEnableTestMode();


  }, // mounted



  methods: {

    recordArm(){
      wavesurferMicMonitor.microphone.start();
      this.isWaitingToRecord = true;
      // wavesurfer.stop();
      // wavesurfer.empty();
      // wavesurfer.clearRegions();
      // wavesurfer.setPlaybackRate(1);
      this.playerAction('clear');
      this.playbackRate = 1;
    },

    record(){
      chunks = [];
      mediaRecorder.start();
      console.log("recorder started", mediaRecorder.state);
      this.isRecording = true;
      
      // Started directly, not from record arm (threshold start)
      if( !this.isWaitingToRecord ){

        // wavesurfer.stop();
        // wavesurfer.empty();
        // wavesurfer.clearRegions();
        this.playerAction('clear');

        // wavesurfer.setPlaybackRate(1);
        this.playbackRate = 1;
        this.isRecording = true;
        // start the microphone
        wavesurferMicMonitor.microphone.start();
      }
      this.isWaitingToRecord = false;
      this.monitorOnStart = false;
      wavesurferMicMonitor.microphone.stopDevice();

    },

    stopRecord(){
      mediaRecorder.stop();
      console.log("recorder stopped", mediaRecorder.state);
      this.isRecording = false;
      this.hasEverRecorded = true;
      this.isWaitingToRecord = false;

      // stop the microphone
      // wavesurferMicMonitor.microphone.stop();
      wavesurferMicMonitor.microphone.stopDevice();
    },

   
    // also used when space pressed on input select, which otherwise triggers dropdown select default behaviour
    handleSpacebarPress(ev){
      ev.preventDefault();
      // if( !this.hasEverRecorded || this.isRecording ){
      //   // if( rec.state === 'recording' ){
      //   if( this.isRecording ){
      //     this.stopRecord();
      //   } else {
      //     this.record();
      //   }
        
      //   return; 
      // } // record if this is first

      // wavesurfer.playPause();
      // this.waveAction = 'playPause';
      console.log('SPACE playPause');
      // This works and seems easiest for now, though
      // "tightly coupled"
      this.playerAction('playPause', 1, 2, 3);
      
      // this.waveStore.status = 'playPause'; // works, but how to trigger on update-but-not-change? same issue as prop+watch



      // this.waveBus.$emit('playPause');
    },


    async getMediaDevices(changed=false){
     console.log('%cgetMediaDevices()', 'color: orange; font-size: 1.3rem');
     
      if(changed){
        console.log('%cmedia device list CHANGE', 'color: red; font-size: 1.5rem;');
      }

      this.prevAudioDevices = { ...this.audioDevices };

      const devices = await navigator.mediaDevices.enumerateDevices();
      console.log({devices});

      const newAudioDevices = {};  // for audio select dropdown
      const audioDevices = devices.filter(d => d.kind === 'audioinput');
      audioDevices.forEach(d => {
        newAudioDevices[d.deviceId] = d.label;
      });

      const prevDeviceCount = Object.keys(this.prevAudioDevices).length;
      const newDeviceCount  = Object.keys(newAudioDevices).length;
      // console.log({ prevDeviceCount, newDeviceCount }); 

      // Device list CHANGE check
      if( changed ){

        if( prevDeviceCount > 0 && prevDeviceCount < newDeviceCount ){
          console.log('%cDEVICE ADDED!', 'color: green; font-weight: bold');
          // ASSUMPTION: newly-added device is always the last in the list - WRONG
          const prevDeviceIds = Object.keys(this.prevAudioDevices);
          const newDeviceIds = Object.keys(newAudioDevices);
          const newId = newDeviceIds.find( id => !prevDeviceIds.includes(id) );
          console.log('newId', newId);
          if( newId ){
            this.selectedInputDevice = newId;
            localStorage.setItem('selectedInputDevice', newId); // save
          }

        } else if(prevDeviceCount > newDeviceCount){
          console.log('%cDEVICE REMOVED!', 'color: red; font-weight: bold');
          // Stop using the removed device, if it was the selected device (use first device in list?)
          if( !(this.selectedInputDevice in newAudioDevices) ){
            console.log('%cDe-selecting removed device', 'color: red; font-weight: bold');
            // TODO: try for preferred device again before defaulting to first?
            this.selectedInputDevice = audioDevices[0].deviceId;
          }
        }

      } else {

        // NOT called due to change, but initial setup
        const preferredDevice = audioDevices.find( d => d.deviceId === this.selectedInputDevice);
        if( !preferredDevice ){
          // Preferred device not found, so default to first device
          console.log('Defaulting to first device:', audioDevices[0]);
          this.selectedInputDevice = audioDevices[0].deviceId;
        }
      
      } // end changed check
     

      this.audioDevices = newAudioDevices;

      // console.groupEnd();

      if( newDeviceCount > 0 ){
        this.initRecorder(); 
        this.initMicMonitor();
      }

    }, // getMediaDevices()


    async initRecorder(){
      console.log('%cinitRecorder():', 'color: red; font-size: 1.2rem');

      if (!navigator.mediaDevices) {
        return console.error('getUserMedia not supported in this browser!');
      }

      // console.log('this.audioDevices', this.audioDevices);
      if( Object.keys(this.audioDevices).length === 0 ){
        console.log('No devices (length = 0)');
        return;
      }

      // console.log('initRecorder(): audio devices', Object.keys(this.audioDevices));
      // console.log('selected', this.selectedInputDevice);
      let options;

      // NOTE: `channelCount: 1` in options below WORKS for Scarlet 2i2
      // but seems to merge both mic inputs down to mono? Oh well!

      // TODO: this should already have been sorted out by this.getMediaDevices()
      if( this.selectedInputDevice in this.audioDevices ){
        console.log('Using selected device', this.selectedInputDeviceName);
        options = { audio: { deviceId: this.selectedInputDevice } };
      } else {
        const firstDevice = Object.keys(this.audioDevices)[0];
        console.log('Using default (first) audio input device', firstDevice);
        // options = { audio: true }; // TODO: does this work?
        options = { audio: { deviceId: firstDevice } };
        this.selectedInputDevice = firstDevice;
      }

      if( this.inputIsMono ){
        options.audio.channelCount = 1;
        // wavesurfer.params.splitChannels = false;
        this.channelCount = 1;
      } else {
        options.audio.channelCount = 2;
        // wavesurfer.params.splitChannels = true;
        this.channelCount = 2;

      }


      // This seems to improve the recording quality
      // but HOW to get raw lossless PCM data instead?
      options.audio.noiseSuppression = false;
      options.audio.echoCancellation = false;

      console.log('%cOPTIONS for initRecorder() getUserMedia()', 'color: red', options, this.audioDevices[this.selectedInputDevice]);

      // TODO: catch errors?
      const stream = await navigator.mediaDevices.getUserMedia( options );
      window.s = stream;
      let tracks = stream.getAudioTracks();
      console.log({tracks});
      // console.log(tracks[0].getSettings().channelCount);

      const recorderOptions = {
        // audioBitsPerSecond: 128000,

        // NOPE: 'unsupported container'
        // mimeType: 'audio/mp4.36', // lossless? https://developer.mozilla.org/en-US/docs/Web/Media/Formats/codecs_parameter

        mimeType: 'audio/webm;codecs=opus' // is this the default anyway?
      };

      mediaRecorder = new MediaRecorder(stream, recorderOptions);
      window.rec = mediaRecorder;
      
      mediaRecorder.onstop = (e) => {
        const blob = new Blob(chunks,  { type: 'audio/wav' }); 
        // Provide to WaveSurfer
        const audio = new Audio();
        audio.src = URL.createObjectURL(blob);
        // wavesurfer.load( audio );
        this.playerAction('load', audio);
        chunks = [];
      }

      mediaRecorder.ondataavailable = (e) => chunks.push(e.data);

      // console.groupEnd();
    }, // initRecorder()

   
    initMicMonitor(){
      console.log('%cinitMicMonitor():', 'color: red; font-size: 1.2rem');


      // Make sure to use selectedInputDevice for mic monitoring too
      const options =  { 
        constraints: {
          audio: { deviceId: this.selectedInputDevice } 
        }
      };
      console.log('%cOPTIONS for initMicMonitor() getUserMedia()', 'color: red', options, this.audioDevices[this.selectedInputDevice]);


      if( wavesurferMicMonitor ){
        console.log('(destroying existing instance)');
        wavesurferMicMonitor.microphone.destroy();
        wavesurferMicMonitor.destroy();
        wavesurferMicMonitor.destroyAllPlugins();
      }

      wavesurferMicMonitor = WaveSurfer.create({
        container:     this.$refs.micMonitor, 
        waveColor:     'orange',
        // waveColor:     'white ',
        // interact:      false,
        fillParent:    true,
        responsive: true,
        // scrollParent:  false,
        // hideScrollbar: true,

        splitChannels: true,

        
        cursorWidth:   0,
        plugins:       [ MicrophonePlugin.create(options) ]
      });

      window.mon = wavesurferMicMonitor;

      wavesurferMicMonitor.setHeight( window.innerHeight * WAVE_HEIGHT_FACTOR );

      if( this.monitorOnStart && !this.testMode ){
        wavesurferMicMonitor.microphone.start();
      }

      

      // Nope! None of it works :shrug:
      // wavesurferMicMonitor.on('audioprocess', e => {
      //   console.log('audioprocess', e);
      // });

      // wavesurferMicMonitor.microphone.on('audioprocess', e => {
      //   console.log('audioprocess', e);
      // });

      wavesurferMicMonitor.microphone.on('deviceReady', (stream)  => {
        console.log('Device ready!', stream);

        // Attach awkwardly to audio process event (keeping existing)
        // const micProc = wavesurferMicMonitor.microphone.levelChecker.onaudioprocess;
        // wavesurferMicMonitor.microphone.levelChecker.onaudioprocess = e => {
        //   micProc(e);
        //   console.log('proc', e);
        // };

        wavesurferMicMonitor.backend.analyser.fftSize = 64;

        if( this.recordThreshold > 0 ){
          wavesurferMicMonitor.microphone.levelChecker.addEventListener('audioprocess', e => {
            if( this.isWaitingToRecord ){
              for (let channel = 0; channel < e.inputBuffer.numberOfChannels; channel++) {
                const inputData = e.inputBuffer.getChannelData(channel);
                for (let sample = 0; sample < e.inputBuffer.length; sample++) {
                  if( Math.abs(inputData[sample]) > this.recordThreshold ){
                    console.log('data', inputData[sample]);
                    this.record();
                    return;
                  }
                }
              }
            }
            // console.log('mic audioprocess', e.inputBuffer);
            // processAudioBuffer(e.inputBuffer);
            // 
            // const bufferLength = wavesurferMicMonitor.backend.analyser.frequencyBinCount;
            // const dataArray = new Uint8Array(bufferLength);
            // wavesurferMicMonitor.backend.analyser.getByteTimeDomainData(dataArray);
            // // console.log(dataArray);
            // let debugBytes = '';
            // for(const d of dataArray){
            //   debugBytes = debugBytes.concat(d.toString());
            //   debugBytes = debugBytes.concat(",");
            // }
            // console.log('d', debugBytes);

          });
        }

      });
      wavesurferMicMonitor.microphone.on('deviceError', function(code) {
          console.warn('Device error: ' + code);
      });

      // console.groupEnd();
    }, // initMicMonitor()







    rangeClick(e){
      // d(e)
      // if( e.originalTarget.nodeName !== 'INPUT' ){
      // }
      // wavesurfer.setPlaybackRate(1);
      this.playbackRate = 1.0;
    },

    async setOutputDevice(){
      const dev = await navigator.mediaDevices.selectAudioOutput();
      console.log({dev});
      this.selectedOutputDevice = dev;
    },


    inputChanged(e){
      console.log('inputChanged');
      localStorage.setItem('selectedInputDevice', this.selectedInputDevice);
      this.$refs.waveform.focus();
      this.initRecorder();
      this.initMicMonitor();
    },

    monoChanged(e){
      const json = JSON.stringify({
        ...this.monoDeviceMap,
        [this.selectedInputDevice]: this.inputIsMono
      })
      console.log('SAVE monoDeviceMap', json, );
      localStorage.setItem('monoDeviceMap', json);
      this.inputChanged();
    },

    restoreState(){
      
      const selected = localStorage.getItem('selectedInputDevice');
      if( selected ){
        // console.log('restore', selected);
        this.selectedInputDevice = selected;
      }

      const monoDeviceMap = localStorage.getItem('monoDeviceMap');
      if(monoDeviceMap){
        this.monoDeviceMap = JSON.parse(monoDeviceMap);
        if(this.selectedInputDevice in this.monoDeviceMap){
          this.inputIsMono = this.monoDeviceMap[this.selectedInputDevice];
        }
      }

    },


    handleScrollZoom(e){
      // console.log('handleScrollZoom');    
      // d(e);
      wavesurfer.zoom( 
        Math.max(MIN_ZOOM_LEVEL, 
          Math.min(MAX_ZOOM_LEVEL, this.zoomLevel - e.deltaY)
        )
      );
      wavesurfer.params.scrollParent = false;
      //  wavesurfer.zoom( Math.max(100, this.zoomLevel-50) );

    },

    getRegionById(id){

    },


    handleWaveClick(e){
      // d(e, e.originalTarget.nodeName)
      if(e.originalTarget.nodeName !== 'REGION'){
        this.regionIsLooping = false;
      }
    },


    handleMiddleClick(e){
      d(e, e.originalTarget.nodeName)
      if(e.originalTarget.nodeName !== 'REGION'){
        // this.regionIsLooping = false;
        console.log('middle clicl, ');
      }
    },


    //  async initFileManager(){

    //   let directory;
      
    //   try {
    //       directory = await window.showDirectoryPicker({
    //           startIn: 'desktop'
    //       });

    //       for await (const entry of directory.values()) {
    //           console.log(entry.name, entry.kind);
    //           // let newEl = document.createElement('div');
    //           // newEl.innerHTML = `<strong>${entry.name}</strong> - ${entry.kind}`;
    //           // document.getElementById('folder-info').append(newEl);
    //       }
    //   } catch(e) {
    //       console.log(e);
    //   }

    // },


    initKeyHandlers(){


      document.addEventListener('keydown', (e) => {
        
        this.keysHeld[e.key] = true;


        // console.log('down', e.code);

        switch( e.code ){
        case 'Tab':
          e.preventDefault();
          // if( rec.state === 'recording' ){
          if( this.isRecording ){
            this.stopRecord();
          } else {
            this.record();
          }
          break;

          case 'ArrowLeft': 
            wavesurfer.setCurrentTime( wavesurfer.getCurrentTime() - 0.1 );
            // wavesurfer.play();
            break;

          case 'ArrowRight': 
            wavesurfer.setCurrentTime( wavesurfer.getCurrentTime() + 0.1 );
            // wavesurfer.play();
            break;

          // up/down: Zoom
          case 'ArrowUp': 
            wavesurfer.zoom( Math.min(MAX_ZOOM_LEVEL, this.zoomLevel+50) );
            // wavesurfer.play();
            wavesurfer.params.scrollParent = false;
            break;

          case 'ArrowDown': 
            wavesurfer.zoom( Math.max(MIN_ZOOM_LEVEL, this.zoomLevel-50) );
            // wavesurfer.play();
            wavesurfer.params.scrollParent = false;
            break;

        }

      });

      document.addEventListener('keyup', (e) => {
        this.keysHeld[e.key] = false;
      });



      document.addEventListener('keypress', (e) => {
        switch( e.code ){
        case 'Space':
          this.handleSpacebarPress(e);
          break;

        case 'KeyP':
          // let region = Object.values(wavesurfer.regions.list)[0];
          this.lastRegion?.playLoop();  // && this.lasregion.playLoop();
          break;

        case 'KeyR':
          if( this.isRecording ) {
            this.stopRecord();
          } else {
            if( this.isWaitingToRecord ){
              this.stopRecord();
            } else {
              this.recordArm();
            }
          }
          break;

        case 'KeyS':
          // TODO: save active region/whole buffer
          this.saveRegion();
          break;

        case 'Comma':
          this.playbackRate = Math.max(0.13, this.playbackRate-0.2);
          break;
        case 'Period':
          this.playbackRate = Math.min(2, this.playbackRate+0.2);
          break;
        case 'Slash':
          this.playbackRate = 1;
          break;

          // Loop ends adjust:

          //  [ , ]  - end adjust
          case 'BracketLeft': this.adjustRegion(
            e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL
          );
            break;
          case 'BracketRight': this.adjustRegion(
            e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL
          );
            break;
            
          //  q, w  - start adjust
          case 'KeyQ': this.adjustRegion(
            e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL,
            'start'
          );
            break;
          case 'KeyW': this.adjustRegion(
            e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL,
            'start'
          );
            break;

          
          case 'Digit1':
          case 'Digit2':
          case 'Digit3':
          case 'Digit4':
          case 'Digit5':
          case 'Digit6':
          case 'Digit7':
          case 'Digit8':
          case 'Digit9':
            this.extendRegion(+e.key);
            break;

          case 'Digit0':
            wavesurfer.zoom(100);
            wavesurfer.params.scrollParent = false;
            break;


        default:
          console.log('Key not handled', e.code, e);          
        }
      });



    },

    
    // Send actions to <Wave> player child component
    // (which controls WaveSurfer instance)
    playerAction(action, ...args){
      this.$refs.wavePlayer.triggerAction(action, ...args);
    },


    // Receive actions from <Wave> player child
    playerStateChange(state, ...args){
      console.log('playerStateChange()', state, args);
      switch(state){
      case 'playing':
        this.hasEverRecorded = true;
        this.monitorOnStart = false;
        break;
      default:
        console.log('%cUNHANDLED player state:', state);
      }
    }, // playerStateChange()




  

    adjustRegion(amt, start=undefined){
      if( !this.lastRegion ) return;
      this.lastRegion.onResize(amt, start); 
    },   

  
    checkEnableTestMode(){
      const urlParams = new URLSearchParams(window.location.search);
      const testMode = urlParams.get('test');
      if( testMode === null ) return;
      
      this.testMode = true;
      console.log('%cTEST MODE', 'color: green; font-size: 18pt');

      // wavesurfer.load( '/CantinaBand3.wav' );
      // wavesurfer.load( '/58sec.wav' );
      this.playerAction('load', '/58sec.wav');
      this.hasEverRecorded = true;
      this.monitorOnStart = false;

      // this.lastRegion = wavesurfer.addRegion({
      //   // start: 0.5827633378932968,
      //   // end: 2.450068399452804,
      //   start: 9.8,
      //   end: 38.7,
      //   loop: true
      // });
      // window.r = this.lastRegion;

      // Start looping this region from ws ready handler 

    }, // checkEnableTestMode()


    // https://stackoverflow.com/a/66799384 - offlineaudiocontext??
    saveRegion(nameExt=''){
      console.log('%csaveRegion()', 'color: green; font-weight: bold;');
      if(!this.lastRegion) return;
      
      if( !this.testMode ){
        const fullWave =  bufferToWave(wavesurfer.backend.buffer, 0, wavesurfer.backend.buffer.length);
        saveFile(fullWave, dateString() + nameExt + '.full.wav');
      }

      let copied;
      try {
        // This borrowed 'copy' code occasionally throws a
        // "RangeError: source array is too long"
        // but if we ignore it... it works anyway?
        // NOPE: longer regions give:
        // "can't access property "length", copied is undefined"
        copied = copy(this.lastRegion, wavesurfer);
        console.log('copied', copied);
      } catch( e ){
        console.log('Error copying region, can we ignore?');
      }
      console.log({copied});
      const regionWave =  bufferToWave(copied, 0, copied.length);
      saveFile(regionWave, dateString() + nameExt + '.wav');

      // DOES NOT WORK - "RangeError: offset is outside the bounds of the DataView"
      // const rate = wavesurfer.backend.buffer.sampleRate;
      // console.log('rate', rate);
      // const wave =  bufferToWave(
      //   wavesurfer.backend.buffer, 
      //   // 0, wavesurfer.backend.buffer.length
      //   this.lastRegion.start * rate, // offset
      //   (this.lastRegion.end - this.lastRegion.start) * rate, // length
      //   // (this.lastRegion.end - this.lastRegion.start)
      // );

    }, // saveRegion()
  
    extendRegion( mult ){
      console.log('%cextendRegion()', 'color:red; font-weight:bold', mult);
      if( !this.lastRegion ) return;

      const r = this.lastRegion;

      if( mult === 1){
        // special case: reset to original length
        const timeSub = (r.end - r.start) - r.data.duration;
        r.onResize(-timeSub);
        r.data.duplicated = 0;
        return;
      }

      const timeAdded = r.data.duration * (mult - 1);
      r.onResize( timeAdded );
      r.data.duplicated = mult;
      
      console.log('dur', r.data.duration);

    }, // extendRegion()



  }, // methods


}

// https://stackoverflow.com/a/55932619
function copy(region, instance){
    var segmentDuration = region.end - region.start

    // If I don't log them out, it doesn't work?
    console.log('copy(): duration: ', segmentDuration);
    console.log('ws full buffer', instance.backend.buffer);
    // console.log('start, end', region.start, region.end);


    var originalBuffer = instance.backend.buffer;
    var emptySegment = instance.backend.ac.createBuffer(
        originalBuffer.numberOfChannels,
        segmentDuration * originalBuffer.sampleRate,
        originalBuffer.sampleRate
    );
    for (var i = 0; i < originalBuffer.numberOfChannels; i++) {
        console.log('copy, channel ', i);
        var chanData = originalBuffer.getChannelData(i);
        var emptySegmentData = emptySegment.getChannelData(i);
        var mid_data = chanData.subarray( region.start * originalBuffer.sampleRate, region.end * originalBuffer.sampleRate);
        emptySegmentData.set(mid_data);
    }

    return emptySegment
}


function processAudioBuffer(buf){
 for (let channel = 0; channel < buf.numberOfChannels; channel++) {
    const inputData = buf.getChannelData(channel);
    // const outputData = outputBuffer.getChannelData(channel);
    // Loop through the 4096 samples
    for (let sample = 0; sample < buf.length; sample++) {
      // make output equal to the same as the input
      // outputData[sample] = inputData[sample];
      // add noise to each output sample
      // outputData[sample] += ((Math.random() * 2) - 1) * 0.2;
      
      if( Math.abs(inputData[sample]) > 0.3 ){
        console.log('data', inputData[sample]);
      }


    }
  }

}

// https://stackoverflow.com/a/62260599
// (C) Ken Fyrstenberg / MIT license
// TODO: format is hardcoded 16bit 44khz?
function bufferToWave(abuffer, offset, len) {

  var numOfChan = abuffer.numberOfChannels,
      length = len * numOfChan * 2 + 44,
      buffer = new ArrayBuffer(length),
      view = new DataView(buffer),
      channels = [], i, sample,
      pos = 0;

  console.log({view});

  // write WAVE header
  setUint32(0x46464952);                         // "RIFF"
  setUint32(length - 8);                         // file length - 8
  setUint32(0x45564157);                         // "WAVE"

  setUint32(0x20746d66);                         // "fmt " chunk
  setUint32(16);                                 // length = 16
  setUint16(1);                                  // PCM (uncompressed)
  setUint16(numOfChan);
  setUint32(abuffer.sampleRate);
  setUint32(abuffer.sampleRate * 2 * numOfChan); // avg. bytes/sec
  setUint16(numOfChan * 2);                      // block-align
  setUint16(16);                                 // 16-bit (hardcoded in this demo)

  setUint32(0x61746164);                         // "data" - chunk
  setUint32(length - pos - 4);                   // chunk length

  // write interleaved data
  for(i = 0; i < abuffer.numberOfChannels; i++)
    channels.push(abuffer.getChannelData(i));

  while(pos < length) {
    for(i = 0; i < numOfChan; i++) {             // interleave channels
      sample = Math.max(-1, Math.min(1, channels[i][offset])); // clamp
      sample = (0.5 + sample < 0 ? sample * 32768 : sample * 32767)|0; // scale to 16-bit signed int
      view.setInt16(pos, sample, true);          // update data chunk
      pos += 2;
    }
    offset++                                     // next source sample
  }

  // create Blob
  return (URL || webkitURL).createObjectURL(new Blob([buffer], {type: "audio/wav"}));

  function setUint16(data) {
    view.setUint16(pos, data, true);
    pos += 2;
  }

  function setUint32(data) {
    view.setUint32(pos, data, true);
    pos += 4;
  }
}

// https://stackoverflow.com/a/48968694
function saveFile(fileURL, filename) {
  if (window.navigator.msSaveOrOpenBlob) {
    window.navigator.msSaveOrOpenBlob(blob, filename);
  } else {
    const a = document.createElement('a');
    document.body.appendChild(a);
    // const url = window.URL.createObjectURL(blob);
    a.href = fileURL;
    a.download = filename;
    a.click();
    setTimeout(() => {
      window.URL.revokeObjectURL(fileURL);
      document.body.removeChild(a);
    }, 0)
  }
}


// https://stackoverflow.com/questions/10645994/how-to-format-a-utc-date-as-a-yyyy-mm-dd-hhmmss-string-using-nodejs
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat/DateTimeFormat#options
function dateString(){
  // return new Date().toISOString().replace('T', '_').replace(':', '.').replace(/\..+/, '');
  return new Date()
    .toLocaleString('default', { dateStyle: 'short', timeStyle: 'medium' })
    .replaceAll('/', '-') // ugh
    .replace(', ', '_')
    .replaceAll(':', '.')
    .replaceAll(' ', '');
}

</script>

<style>

.container {
  text-align: center;
}

#micMonitor {
  max-width: 998px;
  display: none;
  text-align: center;
}

/* #micMonitor > wave{
} */

#micMonitor.recording {
  display: block;
  display: inline-block;
  width: 100%;
}

#waveform {
  display: block;
}
#waveform.recording {
  display: none;
}

/* #waveform {
  width: 90vw;
  margin: 0 auto;
} */

/* .recording {
  border: 2px solid #ff9500e6;
  color: #ff950075; 
} */


#msg {
  z-index: 100;
  font-size: 24pt;
  width: 30wv;
  text-align: center;
  height: 10vh;
  color: #ff9500e6;

}
.rangeResetArea {
  padding: 1rem;
  display: inline-block;
}

div.rangeResetArea:hover > div {
  opacity: 1;
  color: #bbbbbb;
}

div.rangeResetArea > div {
  font-size: 1.5rem;
  transition: 0.1s;
  color: #000000; 
  /* opacity: 0; */
}

/* div.rangeResetArea:hover {
  background-color: #ffffff;
  border: 1px solid red;
} */

region {
  border-left: 1px solid #ffffff22 !important;
  border-right: 1px solid #ffffff22 !important;
}

/* .wavesurfer-handle.wavesurfer-handle-start {
  border-left: 1px solid #999999 !important;
}
.wavesurfer-handle.wavesurfer-handle-end {
  border-right: 1px solid #999999 !important;
}
*/

.wavesurfer-handle.wavesurfer-handle-start:hover {
  border-left: 1px solid #ffffffff !important;
  opacity: 1.0 !important;
  background-color: #ff950022 !important;
}
.wavesurfer-handle.wavesurfer-handle-end:hover {
  border-right: 1px solid #ffffffff !important;
  opacity: 1.0 !important;
  background-color: #ff950022 !important;
} 

.wavesurfer-handle {
  /* border: 1px solid rgba(0,0,0, 0); */
  transition: 0.17s;
}

#outputDevices {
  position: fixed;
  top: 0;
  right: 0;
  z-index: 200;
  transition: 0.3s;
  text-align: center;
  padding: 0.4rem;
  border: none;
  color: grey;
  cursor: pointer;
}

#outputDevices:hover {
  color: white;
}


#inputDevices {
  position: fixed;
  top: 0;
  left: 0;
  z-index: 200;
  text-align: center;
  padding: 0.4rem;
  transition: 0.4s;
}


 #inputDevices select, #inputDevices input {
  background: black;
  color: grey;
  border: 1px solid black;
  
  padding: 0.5rem;
}
#inputDevices label {
  color: white;
  padding-left: 1rem;
}

#inputDevices span.select{
  opacity: 0;
  position: absolute;
  top: 0;
  left: 0;
  white-space: nowrap;
}

#inputDevices:hover span.select {
  /* border: 1px solid grey; */
  opacity: 1.0;
}
#inputDevices:hover select {
  color: white;
}
/* #inputDevices select:has(option:hover){
  opacity: 1.0;
}
#inputDevices select:hover){
  opacity: 1.0;
} */

#inputDevices  span.label {
  opacity: 1.0;
  color: #444444;
}
#inputDevices:hover span.label {
  opacity: 0;
}
#inputDevices span.label:hover {
  opacity: 0;
}



#instructions {
  position: fixed;
  bottom: 0;
  width: 100%;
  height: 2rem;
  color: grey;
  font-size: 10pt;
}
#instructions strong{
  font-weight: bold;
  text-decoration: underline;
}
#instructions:hover {
  color: white;
}

.testModeWarn {
  color: green;
  font-size: 18pt;
}

.rangeResetArea {
  padding: 2rem;
  opacity: 0;
  z-index: -1;
  transition: 0.3s;
}
.rangeResetArea:hover {
  opacity: 1;
  transform: scale(1.5);
}

Slider{
  border: 1px solid red;
}

</style>


