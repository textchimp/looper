<template>
  <div class="container">

    <div id="inputDevices">
        <!-- <span>{{ selectedInputDeviceName }}</span> -->
        <select v-model="selectedInputDevice" @change="inputChanged">
          <option :key="id" v-for="(name, id) in audioDevices" :value="id">In: {{ name }}</option>
        </select>  
    </div>

     <div id="outputDevices"  @click="setOutputDevice" :title="selectedOutputDevice.label">
        <span>Out</span>
     </div>

    <div id="msg">
              

      <div v-if="isRecording">[ recording ]</div>
      <div v-else-if="isWaitingToRecord">[ record arm: {{recordThreshold}} ]</div>

      <div v-if="!isRecording && hasEverRecorded" @click.stop="" class="rangeResetArea">
        <!-- <input @click.stop="" type="range" min="0.1" max="2.0" step="0.01" v-model="playbackRate"> -->
        <Slider v-model="playbackRate"
          label="rate"
          :min="0.13" 
          :max="2" 
          :defaultValue="1" 
          style="height: 30px; width: 400px; margin: 0 auto;" 
        />
      </div>
    </div> 

    <div id="micMonitor" ref="micMonitor" 
      :class="(isRecording || isWaitingToRecord) && 'recording'"
    ></div>

    <div id="waveform" ref="waveform" 
      @wheel="handleScrollZoom" 
      @click="handleWaveClick"
      @auxclick="handleMiddleClick"
      :class="isRecording && 'recording'"
    ></div>

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
const WAVE_HEIGHT_FACTOR = 0.8;

const REGION_RESIZE_SMALL = 0.01;
const REGION_RESIZE_MEDIUM = 0.1;
const REGION_RESIZE_LARGE = 0.2;
let chunks = [];

const env = process.env.NODE_ENV;

/*
TODO:
  - Microphone monitor does not show selected inputs, defaults to first?
  
  - sort out damn play/pause/loop of regions inconsistencies
  - fucking kbd focus on dropdown for tab/space, can't blur the fucker
  - prevent leaving region on scroll
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
import RegionsPlugin from 'wavesurfer.js/dist/plugin/wavesurfer.regions.min.js';
import MicrophonePlugin from 'wavesurfer.js/dist/plugin/wavesurfer.microphone.min.js';

// import VueSlideBar from 'vue-slide-bar';
import Slider from './ui/Slider.vue';

// Keep these out of state?
let wavesurfer = null;
let wavesurferMicMonitor = null;
let mediaRecorder = null;


 export default {
  name: 'Main',
  components: { Slider },
  
  data(){
    return {
      // STATE
      playbackRate: 1.0,
      zoomLevel: MIN_ZOOM_LEVEL,
      regionIsLooping: false,
      isRecording: false,
      isWaitingToRecord: false,
      recordThreshold: 0.1,
      hasEverRecorded: false,
      recordClass: '',
      lastRegion: null,
      regionCount: 0,

      showSplashScreen: true,

      audioDevices: {},
      prevAudioDevices: {}, // for keeping track of added device
      selectedInputDevice: null,
      selectedOutputDevice: {},

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

    // NO! Watchers are async, which is too hard to debug
    // So instead: manually run this.initRecorder() after change to input
    // selectedInputDevice(v){
    //   console.log('%cWATCHER: selectedInputDevice', 'color: blue');
    //   this.initRecorder(); // re-initialise audio input
    // },

  },


  mounted(){
    this.restoreState();

    // this.initFileManager();

    this.initFileDragDrop();

    this.getMediaDevices();

    navigator.mediaDevices.ondevicechange = (e) => {
      // console.log('device change', e);
      this.getMediaDevices(true); // arg indicates change
    };

    this.initWavesurfer();
    // this.initRecorder(); // should happen automatically when getMediaDevices() updates selectedInputDevice (watcher)

    this.$refs.waveform.focus();
  }, // mounted



  methods: {

    recordArm(){
      wavesurferMicMonitor.microphone.start();
      this.isWaitingToRecord = true;
      wavesurfer.stop();
      wavesurfer.empty();
      wavesurfer.clearRegions();
      // wavesurfer.setPlaybackRate(1);
      this.playbackRate = 1;
    },

    record(){
      chunks = [];
      mediaRecorder.start();
      console.log("recorder started", mediaRecorder.state);
      this.isRecording = true;
      
      // Started directly, not from record arm (threshold start)
      if( !this.isWaitingToRecord ){
        wavesurfer.stop();
        wavesurfer.empty();
        wavesurfer.clearRegions();
        // wavesurfer.setPlaybackRate(1);
        this.playbackRate = 1;
        this.isRecording = true;
        // start the microphone
        wavesurferMicMonitor.microphone.start();
      }
      this.isWaitingToRecord = false;

    },

    stopRecord(){
      mediaRecorder.stop();
      console.log("recorder stopped", mediaRecorder.state);
      this.isRecording = false;
      this.hasEverRecorded = true;
      this.isWaitingToRecord = false;

      // stop the microphone
      wavesurferMicMonitor.microphone.stop();
    },


   

    initWavesurfer(){

      wavesurfer = WaveSurfer.create({
        container: this.$refs.waveform, // << slight FOUC  
        //container: document.querySelector('#waveform'),
        waveColor: '#A8DBA8',
        progressColor: '#3B8686',

        fillParent: true,
        scrollParent: false,
        hideScrollbar: false,
        // minPxPerSec: 50,
        // pixelRatio: 1,
        // autocenter: true,

        backend: 'MediaElement',  // wavesurfer.backend  ??? MediaElement / WebAudio
        plugins: [
            
            // MicrophonePlugin.create(),

            RegionsPlugin.create({
                // regionsMinLength: 2,
                // regions: [
                //     {
                //         start: 1,
                //         end: 3,
                //         loop: false,
                //         color: 'hsla(400, 100%, 30%, 0.5)'
                //     }, {
                //         start: 5,
                //         end: 7,
                //         loop: true,
                //         color: 'hsla(200, 50%, 70%, 0.4)',
                //         minLength: 1,
                //         maxLength: 5,
                //     }
                // ],
                dragSelection: {
                    slop: 5 // 5
                }
            })  // RegionsPlugin.create()
        ]
      });

      wavesurfer.setHeight( window.innerHeight * WAVE_HEIGHT_FACTOR );


      // wavesurfer.microphone.on('deviceReady', () => {
      //   console.info('Device ready!');
      //   wavesurfer.microphone.start();
      // });

      //
      // if (wavesurfer.microphone.active) {
      //     wavesurfer.microphone.stop();


      wavesurfer.on('error', function(e) {
          console.warn(e);
      });

      wavesurfer.on('ready', e => {
        console.log('duration:', wavesurfer.getDuration() );
        // wavesurfer.addRegion({
        //   start: 0,
        //   end: wavesurfer.getDuration(),
        //   minLength: 0, 
        //   maxLength: wavesurfer.getDuration(),
        //   loop: true,
        //   color: 'hsla(50, 100%, 30%, 0.5)'
        // });


        wavesurfer.play(); // play once on recording end
        console.log( Object.values(wavesurfer.regions.list) );

        wavesurfer.on('finish', () => {
          wavesurfer.play();
        });

      });  

      wavesurfer.on('region-click', e => {

        const region = wavesurfer.regions.list[e.id];
        
        if( this.keysHeld.Meta ){
          region.remove();
          return;  
        }

        region.play();
        region.loop = true;
        this.regionIsLooping = true;
        console.log('region click', region, e);
        this.lastRegion = region;
      });

      
      wavesurfer.on('zoom', r => {
        // console.log('zoom', r);
        this.zoomLevel = r;
      });


      // region-created fires as soon as you start dragging, not when finished
      wavesurfer.on('region-created', r => {
        console.log('region-created', r);
        console.log( Object.values(wavesurfer.regions.list) );
        r.color = '#ff950022';
        r.loop = true;
        r.element.children[0].style.width='1rem';
        r.element.children[0].style.opacity='0.1';
        r.element.children[1].style.width='1rem';
        r.element.children[1].style.opacity='0.1';
      }); // on region created
      // region-created fires as soon as you start dragging, not when finished



      // wavesurfer.on('waveform-ready', r => {
      //   console.log('waveform-ready');
      //   const lowpass = wavesurfer.backend.ac.createBiquadFilter();
      //   wavesurfer.backend.setFilter(lowpass);
      //   window.lowpass = lowpass;
      // });

      wavesurfer.on('region-update-end', r => {

        const duration = r.end - r.start;
        if( duration < 0.1 && !r.created ){
          r.remove(); // ignore new regions that are too small
          return;
        }

        r.created = true; // private use
        r.loop = true;
        this.regionIsLooping = true;

        // console.log('region-update-end', r.start, r.end);
        // console.log( Object.values(wavesurfer.regions.list) );
        window.r = r;
        this.lastRegion = r;

        r.play();  // playLoop?

        // if(wavesurfer.getCurrentTime > r.end){
        //   wavesurfer.setCurrentTime(r.start); 
        // }

      }); // on region created


      // region-play
      // region-in
      // region-out

      wavesurfer.on('region-out', r => {
        const region = wavesurfer.regions.list[r.id];
        // wavesurfer.play(region);
        // console.log('region out', region.start);
        if( this.regionIsLooping && this.lastRegion && region.id === this.lastRegion.id ){
          wavesurfer.setCurrentTime(region.start); //TODO: check if region has changed
        }
      });

      // wavesurfer.load('/bass.wav'); // Load audio from URL
      window.w   = wavesurfer;


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

          // return;
          // wavesurfer.microphone.start();
          // return;

          // if( this.lastRegion ){
          //   this.lastRegion.playLoop();
          // }
          
          if( !this.hasEverRecorded || this.isRecording ){
            // if( rec.state === 'recording' ){
            if( this.isRecording ){
              this.stopRecord();
            } else {
              this.record();
            }

            return; 
          } // record if this is first

          wavesurfer.playPause();
          break;

        case 'KeyP':
          // let region = Object.values(wavesurfer.regions.list)[0];
          this.lastRegion?.playLoop();  // && this.lasregion.playLoop();
          break;

        case 'KeyR':
          // let region = Object.values(wavesurfer.regions.list)[1];
          // region.playLoop();
          // if( this.isRecording ){
          //   this.hasEverRecorded = true;
          //   this.stopRecord();
          // } else {
          //   this.record();
          // }
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

          if(!this.lastRegion) return;

          const copied = copy(this.lastRegion, wavesurfer);
          console.log('copied', copied);

          const regionWave =  bufferToWave(copied, 0, copied.length);
          saveFile(regionWave, dateString() + '.wav');

          // const rate = wavesurfer.backend.getAudioContext().sampleRate;
          // console.log('rate', rate);
          // const wave =  bufferToWave(
          //   wavesurfer.backend.buffer, 
          //   // 0, 
          //   // wavesurfer.backend.buffer.length
          //   this.lastRegion.start * rate / 2.0, // offset
          //   (this.lastRegion.end - this.lastRegion.start) * rate / 2.0, // length
          //   // (this.lastRegion.end - this.lastRegion.start)
          // );


          // const wave =  bufferToWave(wavesurfer.backend.buffer, 0, wavesurfer.backend.buffer.length);
          // saveFile(wave, dateString() + '.wav');
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



        default:
          console.log('Key not handled', e.code, e);          
        }
      });

      this.initMicMonitor();

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

      if( newDeviceCount > 0 ){
        this.initRecorder(); // WAS: in mounted() independent of this
      }

    }, // getMediaDevices()


    async initRecorder(){
      console.log('%cinitRecorder():', 'color: red; font-size: 1.2rem', this.selectedInputDevice);

      if (!navigator.mediaDevices) {
        return console.error('getUserMedia not supported in this browser!');
      }

      console.log('this.audioDevices', this.audioDevices);
      if( Object.keys(this.audioDevices).length === 0 ){
        console.log('No devices (length = 0)');
        return;
      }

      console.log('initRecorder(): audio devices', Object.keys(this.audioDevices));
      console.log('selected', this.selectedInputDevice);
      let options;

      // TODO: this should already have been sorted out by this.getMediaDevices()
      if( this.selectedInputDevice in this.audioDevices ){
        console.log('Using selected device', this.selectedInputDeviceName);
        options = { audio: { deviceId: this.selectedInputDevice } };
      } else {
        console.log('Using default audio input device?');
        // options = { audio: true };
        options = { audio: { deviceId: this.selectedInputDevice } };
      }

      const stream = await navigator.mediaDevices.getUserMedia( options );
      // .then(stream => {
      console.log('stream options:', options);

        mediaRecorder = new MediaRecorder(stream);
        window.rec = mediaRecorder;
        
        mediaRecorder.onstop = (e) => {
          const blob = new Blob(chunks, { 'type' : 'audio/webm; codecs=pcm' });
          // window.open(URL.createObjectURL(blob));
          // Provide to WaveSurfer
          const audio = new Audio();
          audio.src = URL.createObjectURL(blob);
          wavesurfer.load( audio );
          chunks = [];
        }

        mediaRecorder.ondataavailable = (e) => chunks.push(e.data);

      // })
      // .catch(err => {
      //   console.log('The following error occurred: ' + err);
      // });

    }, // initRecorder()

    // wavesurferAdd( audio ){

    //   // wavesurfer.loadBlob( audio ); // doesn't work! 
    //   wavesurfer.load( audio );
      
    // }, // wavesurferAdd()


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
    },

    restoreState(){
      const selected = localStorage.getItem('selectedInputDevice');
      if( selected ){
        console.log('restore', selected);
        this.selectedInputDevice = selected;
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


    initFileDragDrop(){

      document.addEventListener("dragover", (event) => {
        event.preventDefault();
      }, false);

      document.addEventListener("drop", (event) => {
        event.preventDefault();
        // d('item', event.dataTransfer.items[0])
        const file =  event.dataTransfer.files[0];

        // Latest
        if (file) {
          const reader = new FileReader();
          reader.onload = (ev) => {
            chunks = [];
            const audio = new Audio();
            console.log('result', ev.target.result);
            // Create a Blob providing as first argument a typed array with the file buffer
            var blob = new window.Blob([new Uint8Array(ev.target.result)]);
            audio.src = URL.createObjectURL(blob);
            const loader = wavesurfer.load(audio); 
            // console.log('loader', loader); // nothing
            // wavesurfer.addRegion({
            //   start: 0,
            //   end: wavesurfer.getDuration(),
            //   minLength: 0, 
            //   maxLength: wavesurfer.getDuration(),
            //   loop: true,
            //   color: 'hsla(50, 100%, 30%, 0.5)'
            // });
            //
            // wavesurfer.loadBlob(blob); 
            // ^^^ Error:
            // Error decoding audiobuffer Main.vue:246:19
            // HTTP “Content-Type” of “text/html” is not supported. Load of media resource http://localhost:5173/[object%20AudioBuffer] failed. localhost:5173
            // Cannot play media. No decoders for requested formats: text/html
          };
          reader.onerror = function (evt) {
              console.error("An error ocurred reading the file: ", evt);
          };

          // reader.readAsDataURL(file);
           reader.readAsArrayBuffer(file);
        }

        // for (let i=0; i<items.length; i++) {
        //   let item = items[i].webkitGetAsEntry(); // FF only?
        //   if (item) {
        //       // scanFiles(item, listing);
        //       d(item)
        //       // console.log(item.file());
        //
        //       item.file(file => {
        //         let reader = new FileReader();
        //         console.log('reader', file);
        //         // wavesurfer.load(file);
        //
        //         reader.onload = (ev) => {
        //
        // FileReader.readAsArrayBuffer()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains an ArrayBuffer representing the file's data.
        // FileReader.readAsBinaryString()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains the raw binary data from the file as a string.
        // FileReader.readAsDataURL()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains a data: URL representing the file's data.
        // FileReader.readAsText()
        // 
        //           // successCallback(reader.result);
        //           console.log('SUCCESS', reader.readyState);
        //           const blob = new Blob([new Uint8Array(reader.result)]);
        //           wavesurfer.loadBlob(blob);
        //           // console.log('SUCCESS', reader.result);
        //           // const blob = new Blob(reader.result);
        //           // wavesurfer.loadBlob(reader.result);
        // 
        //           // const audio = new Audio();
        //           // audio.src = URL.createObjectURL(blob);
        //           // wavesurferAdd(audio);
        //           // chunks = [];
        //         };
        //
        //         reader.onerror = () => {
        //           // errorCallback(reader.error);
        //           console.log('ERR', reader.error);
        //         }
        //
        //           // reader.readAsText(file);
        //           // reader.readAsBinaryString(file);
        //           reader.readAsArrayBuffer(file);
        //
        //       }, console.warn); // open each file dropped
        //   }
        // }


      }, false); // on drop


    }, // initFileDragDrop()


    initMicMonitor(){

      wavesurferMicMonitor = WaveSurfer.create({
        container:     this.$refs.micMonitor, //document.querySelector('#micMonitor'),
        waveColor:     'orange',
        interact:      false,
        fillParent:    true,
        scrollParent:  false,
        hideScrollbar: true,
        cursorWidth:   0,
        plugins:       [ MicrophonePlugin.create() ]
      });

      window.mon = wavesurferMicMonitor;

      wavesurferMicMonitor.setHeight( window.innerHeight * WAVE_HEIGHT_FACTOR );

      

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

    
    },

    adjustRegion(amt, start=undefined){
      if( !this.lastRegion ) return;
      this.lastRegion.onResize(amt, start); 
    },   

    // adjustRegionEnd(amt){
    //   if( !this.lastRegion ) return;
    //   this.lastRegion.onResize(amt); 
    // },   


  }, // methods


}

// https://stackoverflow.com/a/55932619
function copy(region, instance){
    var segmentDuration = region.end - region.start

    // If I don't log them out, it doesn't work?
    console.log('copy(): duration: ', segmentDuration);
    console.log('ws', instance.backend.buffer);
    console.log('start, end', region.start, region.end);

    var originalBuffer = instance.backend.buffer;
    var emptySegment = instance.backend.ac.createBuffer(
        originalBuffer.numberOfChannels,
        segmentDuration * originalBuffer.sampleRate,
        originalBuffer.sampleRate
    );
    for (var i = 0; i < originalBuffer.numberOfChannels; i++) {
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

// https://stackoverflow.com/a/48968694
function saveRangeToFile(fileURL, filename, start, end) {
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
      window.URL.revokeObjectURL(url);
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
  transition: 1s;
  text-align: center;
  padding: 0.4rem;
}

 #inputDevices select {
  background: black;
  color: grey;
  border: 1px solid black;
  /* display: none; */
}
#inputDevices:hover select{
  border: 1px solid grey;
}

/* #inputDevices select {
  background: black;
  color: white;
  border: none;
  display: none;
}
#inputDevices:hover select, #inputDevices select:hover {
  display: block;
  border: 1px solid grey;
} */
/* 
#inputDevices label {
  display: block;
  text-align: center;
}
#inputDevices:hover label {
  display: none;
} */

#inputDevices label span {
  color: white;
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
</style>


