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
          /> Mono</label>
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

window.d = d; // use everywhere

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
    
    // playbackRate(v){
    //   if( v > 0.13 && v < 2.7 ){
    //     wavesurfer.setPlaybackRate(Number(v));
    //   } 
    // },

    // lowpassFilterFreq(v){
    //   console.log('lowpass', v);
    //   // l.frequency.value = v;
    //   g.gain.value = v;
    // },

    // stereoPan(v){
    //   filters.panner.pan.value = v;
    //   d(v);
    // },

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
      // .... if devices are available

    navigator.mediaDevices.ondevicechange = (e) => {
      this.getMediaDevices(true); // arg indicates change, not init
    };

    this.initKeyHandlers();

    // Enable test mode from ?test= param
    this.checkEnableTestMode();

  }, // mounted



  methods: {

    recordArm(){
      wavesurferMicMonitor.microphone.start();
      this.isWaitingToRecord = true;
      this.playerAction('clear');
      this.playbackRate = 1; // FIXME
    },

    record(){
      chunks = [];
      mediaRecorder.start();
      console.log("recorder started", mediaRecorder.state);
      this.isRecording = true;
      
      // Started directly, not from record arm (threshold start)
      if( !this.isWaitingToRecord ){
        this.playerAction('clear');
        this.playbackRate = 1; // FIXME
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
      if( !this.hasEverRecorded || this.isRecording ){
        // if( rec.state === 'recording' ){
        if( this.isRecording ){
          this.stopRecord();
        } else {
          this.record();
        }
        
        return; 
      } // record if this is first

      // This works and seems easiest for now, though "tightly coupled"
      this.playerAction('playPause');
      
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



    getRegionById(id){

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

        } // switch

      });


      document.addEventListener('keyup', (e) => {
        this.keysHeld[e.key] = false;
      });


      document.addEventListener('keypress', (e) => {
        switch( e.code ){
        case 'Space':
          this.handleSpacebarPress(e);
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
      console.log('MAIN received playerStateChange()', state, args);
      switch(state){
      case 'playing':
        this.hasEverRecorded = true;
        this.monitorOnStart = false;
        break;
      default:
        console.log('%cUNHANDLED player state:', state);
      }
    }, // playerStateChange()


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




  }, // methods


}; // Vue component



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


