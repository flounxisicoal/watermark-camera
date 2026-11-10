import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { geoLocationManager } from '@kit.LocationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WatermarkStyle, WatermarkOptions, WatermarkUtil } from '../utils/WatermarkUtil';

const TAG: string = 'WatermarkCamera';

/** 格式化时间为 "YYYY-MM-DD HH:mm:ss" */
function formatTimestamp(date: Date): string {
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/**
 * 水印相机主页面
 *
 * 流程：
 *  1. XComponent 提供预览 Surface，初始化相机（CameraKit）。
 *  2. 点击拍照 -> PhotoOutput.capture。
 *  3. photoAvailable 回调拿到 JPEG 数据：
 *       - 原片字节直接写入 files/photos/original（无水印）
 *       - 解码为 PixelMap -> WatermarkUtil 绘制时间戳 -> 编码 JPEG
 *       - 写入 files/photos/watermark（带水印）
 *  4. 可选：把水印照片保存到系统相册（PhotoAccessHelper）。
 */
@Entry
@Component
struct CameraPage {
  private xComponentController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private cameraManager: camera.CameraManager | undefined = undefined;
  private cameraInput: camera.CameraInput | undefined = undefined;
  private previewOutput: camera.PreviewOutput | undefined = undefined;
  private photoOutput: camera.PhotoOutput | undefined = undefined;
  private photoSession: camera.PhotoSession | undefined = undefined;
  private currentPosition: camera.CameraPosition = camera.CameraPosition.CAMERA_POSITION_BACK;

  @State statusText: string = '正在初始化相机…';
  @State originalUri: string = '';
  @State watermarkUri: string = '';
  @State watermarkTime: string = '';
  @State isBusy: boolean = false;
  // 缩放
  @State zoomRatio: number = 1;
  @State minZoom: number = 1;
  @State maxZoom: number = 1;
  // 点击对焦
  @State focusRingVisible: boolean = false;
  @State focusX: number = 0;
  @State focusY: number = 0;
  // 预览区域尺寸（vp），用于点击坐标换算与拖动框定位
  @State previewW: number = 0;
  @State previewH: number = 0;
  // 双指缩放起始倍率
  private baseZoom: number = 1;
  // 水印设置
  @State showSettings: boolean = false;
  @State customText: string = '';
  @State showTimestamp: boolean = true;
  @State styleIndex: number = 0;
  @State positionIndex: number = 8;
  @State sizeIndex: number = 1;
  @State colorIndex: number = 0;
  @State watermarkOpacity: number = 1.0;
  // 自由拖动水印位置
  @State useCustomPos: boolean = false;
  @State posX: number = 0.5;
  @State posY: number = 0.5;
  // 地理位置
  @State locationText: string = '';
  @State showLocation: boolean = true;
  @State locating: boolean = false;
  private dragStartX: number = 0.5;
  private dragStartY: number = 0.5;
  private readonly styleNames: Array<string> = ['经典', '简约', '描边', '强调'];
  private readonly sizeNames: Array<string> = ['小', '中', '大'];
  private readonly sizeScales: Array<number> = [0.8, 1.0, 1.3];
  private readonly positionCells: Array<number> = [0, 1, 2, 3, 4, 5, 6, 7, 8];
  private readonly colors: Array<string> = ['#FFFFFF', '#000000', '#FFD400', '#FF3B30', '#0F7BFF', '#34C759'];

  /** photoAvailable 监听器（保存引用以便解绑） */
  private photoListener = (err: BusinessError, photo: camera.Photo): void => {
    if (err) {
      hilog.error(0x0000, TAG, 'photoAvailable error: %{public}s', JSON.stringify(err));
      this.statusText = '拍照失败';
      this.isBusy = false;
      return;
    }
    this.handlePhoto(photo);
  };

  aboutToDisappear(): void {
    this.releaseCamera();
  }

  // ==================== 相机初始化 ====================

  private async initCamera(): Promise<void> {
    if (this.surfaceId === '') {
      this.statusText = '预览组件未就绪';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const granted: boolean = await this.ensureCameraPermission(context);
      if (!granted) {
        this.statusText = '缺少相机权限，无法拍照';
        return;
      }

      const manager: camera.CameraManager = camera.getCameraManager(context);
      this.cameraManager = manager;
      const cameras: Array<camera.CameraDevice> = manager.getSupportedCameras();
      if (cameras.length === 0) {
        this.statusText = '未检测到摄像头';
        return;
      }
      const device: camera.CameraDevice = this.pickCamera(cameras);

      const input: camera.CameraInput = manager.createCameraInput(device);
      this.cameraInput = input;
      await input.open();

      const capability: camera.CameraOutputCapability =
        manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile: camera.Profile = capability.previewProfiles[0];
      const photoProfile: camera.Profile = this.pickMaxPhotoProfile(capability.photoProfiles);

      const previewOutput: camera.PreviewOutput =
        manager.createPreviewOutput(previewProfile, this.surfaceId);
      this.previewOutput = previewOutput;
      const photoOutput: camera.PhotoOutput = manager.createPhotoOutput(photoProfile);
      this.photoOutput = photoOutput;

      const session: camera.PhotoSession =
        manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
      this.photoSession = session;

      session.beginConfig();
      session.addInput(input);
      session.addOutput(previewOutput);
      session.addOutput(photoOutput);
      await session.commitConfig();
      await session.start();

      photoOutput.on('photoAvailable', this.photoListener);
      this.initZoomAndFocus(session);
      this.refreshLocation();
      this.statusText = '相机已就绪';
      hilog.info(0x0000, TAG, 'Camera started, position: %{public}d', this.currentPosition);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'initCamera failed: %{public}s', JSON.stringify(err));
      this.statusText = '相机初始化失败，请检查权限或设备';
      await this.releaseCamera();
    }
  }

  private pickCamera(cameras: Array<camera.CameraDevice>): camera.CameraDevice {
    for (const device of cameras) {
      if (device.cameraPosition === this.currentPosition) {
        return device;
      }
    }
    return cameras[0];
  }

  /** 选择分辨率最高的 JPEG 拍照档位（HEIC 档位无法按 JPEG 组件取图） */
  private pickMaxPhotoProfile(profiles: Array<camera.Profile>): camera.Profile {
    const jpegProfiles: Array<camera.Profile> = profiles.filter(
      (profile: camera.Profile) => profile.format === camera.CameraFormat.CAMERA_FORMAT_JPEG
    );
    const candidates: Array<camera.Profile> = jpegProfiles.length > 0 ? jpegProfiles : profiles;
    let best: camera.Profile = candidates[0];
    for (const profile of candidates) {
      const area: number = profile.size.width * profile.size.height;
      const bestArea: number = best.size.width * best.size.height;
      if (area > bestArea) {
        best = profile;
      }
    }
    return best;
  }

  // ==================== 自动对焦 / 缩放 ====================

  /** 初始化连续自动对焦，并读取缩放倍率范围 */
  private initZoomAndFocus(session: camera.PhotoSession): void {
    try {
      const range: Array<number> = session.getZoomRatioRange();
      if (range.length >= 2) {
        this.minZoom = range[0];
        this.maxZoom = range[1];
        // 启动时回到 1.0x 常规视角（部分设备默认停在 0.5x 超广角）
        const initial: number = Math.min(this.maxZoom, Math.max(this.minZoom, 1));
        session.setZoomRatio(initial);
        this.zoomRatio = initial;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'getZoomRange failed: %{public}d', err.code);
    }
    try {
      // 默认连续自动对焦
      session.setFocusMode(camera.FocusMode.FOCUS_MODE_CONTINUOUS_AUTO);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'setFocusMode failed: %{public}d', err.code);
    }
  }

  /** 设置缩放倍率（滑杆与双指捏合共用） */
  private applyZoom(ratio: number): void {
    const session: camera.PhotoSession | undefined = this.photoSession;
    if (!session) {
      return;
    }
    const clamped: number = Math.min(this.maxZoom, Math.max(this.minZoom, ratio));
    try {
      session.setZoomRatio(clamped);
      this.zoomRatio = clamped;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'setZoomRatio failed: %{public}d', err.code);
    }
  }

  /** 点击预览区域对焦 */
  private onPreviewTap(event: ClickEvent): void {
    const width: number = this.previewW > 0 ? this.previewW : 1;
    const height: number = this.previewH > 0 ? this.previewH : 1;
    const xRatio: number = Math.min(1, Math.max(0, event.x / width));
    const yRatio: number = Math.min(1, Math.max(0, event.y / height));

    this.focusX = event.x;
    this.focusY = event.y;
    this.focusRingVisible = true;
    setTimeout(() => {
      this.focusRingVisible = false;
    }, 1200);

    const session: camera.PhotoSession | undefined = this.photoSession;
    if (!session) {
      return;
    }
    try {
      const point: camera.Point = { x: xRatio, y: yRatio };
      session.setFocusPoint(point);
      session.setFocusMode(camera.FocusMode.FOCUS_MODE_AUTO);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'setFocusPoint failed: %{public}d', err.code);
    }
  }

  private async ensureCameraPermission(context: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    // 相机 + 位置（精确定位需同时申请模糊定位）
    const permissions: Array<Permissions> = [
      'ohos.permission.CAMERA',
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION'
    ];
    try {
      const result = await atManager.requestPermissionsFromUser(context, permissions);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'request permission failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  // ==================== 地理位置 ====================

  /** 获取当前位置并解析地址；失败时回退到最近位置/经纬度 */
  private async refreshLocation(): Promise<void> {
    if (this.locating) {
      return;
    }
    this.locating = true;
    try {
      let latitude: number = 0;
      let longitude: number = 0;
      try {
        const current: geoLocationManager.Location = await geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          scenario: geoLocationManager.LocationRequestScenario.UNSET,
          timeoutMs: 6000
        });
        latitude = current.latitude;
        longitude = current.longitude;
      } catch (error) {
        // 兜底：使用最近一次定位结果
        const last: geoLocationManager.Location = geoLocationManager.getLastLocation();
        latitude = last.latitude;
        longitude = last.longitude;
      }
      this.locationText = await this.describeLocation(latitude, longitude);
      hilog.info(0x0000, TAG, 'location resolved: %{public}s', this.locationText);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'refreshLocation failed: %{public}d', err.code);
      this.locationText = '';
    } finally {
      this.locating = false;
    }
  }

  /** 经纬度反查地址，失败时返回坐标文本 */
  private async describeLocation(latitude: number, longitude: number): Promise<string> {
    try {
      if (geoLocationManager.isGeocoderAvailable()) {
        const addresses: Array<geoLocationManager.GeoAddress> =
          await geoLocationManager.getAddressesFromLocation({
            latitude: latitude,
            longitude: longitude,
            maxItems: 1,
            locale: 'zh-CN'
          });
        if (addresses.length > 0) {
          const address: geoLocationManager.GeoAddress = addresses[0];
          const place: string = address.placeName !== undefined ? address.placeName : '';
          if (place !== '') {
            return place;
          }
          const parts: Array<string> = [];
          const fields: Array<string | undefined> = [
            address.administrativeArea,
            address.locality,
            address.subLocality,
            address.roadName,
            address.premises
          ];
          for (const field of fields) {
            if (field !== undefined && field !== '' && parts.indexOf(field) < 0) {
              parts.push(field);
            }
          }
          if (parts.length > 0) {
            return parts.join(' ');
          }
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'reverse geocode failed: %{public}d', err.code);
    }
    return `${latitude.toFixed(4)}, ${longitude.toFixed(4)}`;
  }

  // ==================== 水印拖动定位 ====================

  /** 当前水印锚点的归一化 X */
  private anchorNormX(): number {
    if (this.useCustomPos) {
      return this.posX;
    }
    const col: number = this.positionIndex % 3;
    return col === 0 ? 0.06 : (col === 1 ? 0.5 : 0.94);
  }

  /** 当前水印锚点的归一化 Y */
  private anchorNormY(): number {
    if (this.useCustomPos) {
      return this.posY;
    }
    const row: number = Math.floor(this.positionIndex / 3);
    return row === 0 ? 0.06 : (row === 1 ? 0.5 : 0.94);
  }

  private onWatermarkDragStart(): void {
    this.dragStartX = this.anchorNormX();
    this.dragStartY = this.anchorNormY();
    this.useCustomPos = true;
  }

  private onWatermarkDragUpdate(event: GestureEvent): void {
    const width: number = this.previewW > 0 ? this.previewW : 1;
    const height: number = this.previewH > 0 ? this.previewH : 1;
    this.posX = Math.min(0.97, Math.max(0.03, this.dragStartX + event.offsetX / width));
    this.posY = Math.min(0.97, Math.max(0.03, this.dragStartY + event.offsetY / height));
  }

  /** 组装水印选项 */
  private buildWatermarkOptions(timestamp: string): WatermarkOptions {
    let style: WatermarkStyle = WatermarkStyle.CLASSIC;
    if (this.styleIndex === 1) {
      style = WatermarkStyle.MINIMAL;
    } else if (this.styleIndex === 2) {
      style = WatermarkStyle.OUTLINE;
    } else if (this.styleIndex === 3) {
      style = WatermarkStyle.ACCENT;
    }
    const options: WatermarkOptions = {
      text: this.customText,
      showTimestamp: this.showTimestamp,
      timestamp: timestamp,
      style: style,
      position: this.positionIndex,
      fontScale: this.sizeScales[this.sizeIndex],
      opacity: this.watermarkOpacity,
      color: this.colors[this.colorIndex],
      useCustomPosition: this.useCustomPos,
      x: this.posX,
      y: this.posY,
      location: this.showLocation ? this.locationText : ''
    };
    return options;
  }

  // ==================== 拍照 ====================

  private onCapture(): void {
    const output: camera.PhotoOutput | undefined = this.photoOutput;
    if (!output) {
      this.statusText = '相机尚未就绪';
      return;
    }
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.statusText = '正在拍照并保存…';

    const settings: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation: camera.ImageRotation.ROTATION_0,
      mirror: false
    };

    output.capture(settings, (err: BusinessError) => {
      if (err) {
        hilog.error(0x0000, TAG, 'capture failed: %{public}s', JSON.stringify(err));
        this.statusText = '拍照失败';
        this.isBusy = false;
      }
    });
  }

  /**
   * 处理拍照结果：保存无水印原片 + 带时间戳水印照片
   */
  private async handlePhoto(photo: camera.Photo): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const mainImage: image.Image = photo.main;
      const component: image.Component = await mainImage.getComponent(image.ComponentType.JPEG);
      const jpegBuffer: ArrayBuffer = component.byteBuffer;

      const now: Date = new Date();
      const timestamp: string = formatTimestamp(now);
      const baseName: string = now.getTime().toString();

      // 1. 保存无水印原片（直接写拍照得到的 JPEG 字节）
      const originalBytes: Uint8Array = new Uint8Array(jpegBuffer);
      const originalPath: string = WatermarkUtil.saveBytesToSandbox(
        context, originalBytes, 'original', `${baseName}_original.jpg`
      );

      // 2. 解码 -> 绘制时间戳 -> 编码
      const imageSource: image.ImageSource = image.createImageSource(jpegBuffer);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({ editable: true });
      const watermarkedPixelMap: image.PixelMap =
        WatermarkUtil.addTimestampWatermark(pixelMap, this.buildWatermarkOptions(timestamp));
      const watermarkedBuffer: ArrayBuffer = await WatermarkUtil.packJpeg(watermarkedPixelMap);

      // 3. 保存水印照片
      const watermarkPath: string = WatermarkUtil.saveBytesToSandbox(
        context, new Uint8Array(watermarkedBuffer), 'watermark', `${baseName}_watermark.jpg`
      );

      // 4. 更新界面
      this.originalUri = `file://${originalPath}`;
      this.watermarkUri = `file://${watermarkPath}`;
      this.watermarkTime = timestamp;
      this.statusText = '已保存：原片 + 水印照片';
      hilog.info(0x0000, TAG, 'saved original=%{public}s watermark=%{public}s',
        originalPath, watermarkPath);

      // 5. 释放资源
      await pixelMap.release();
      await watermarkedPixelMap.release();
      await imageSource.release();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'handlePhoto failed: code=%{public}d message=%{public}s',
        err.code, err.message);
      this.statusText = '保存失败';
    } finally {
      this.isBusy = false;
      await photo.release();
    }
  }

  // ==================== 保存到系统相册 ====================

  private async saveWatermarkToAlbum(): Promise<void> {
    if (this.watermarkUri === '') {
      this.statusText = '还没有可保存的水印照片';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      // 写相册需要 WRITE_IMAGEVIDEO 权限，首次点击时动态申请
      const albumPermissions: Array<Permissions> = ['ohos.permission.WRITE_IMAGEVIDEO'];
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, albumPermissions);
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const sourcePath: string = this.watermarkUri.replace('file://', '');
      const srcFile = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
      const srcStat = fs.statSync(sourcePath);
      const readBuffer = new ArrayBuffer(srcStat.size);
      fs.readSync(srcFile.fd, readBuffer);
      fs.closeSync(srcFile);

      const dstFile = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(dstFile.fd, readBuffer);
      fs.closeSync(dstFile);

      this.statusText = '水印照片已保存到相册';
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'save to album failed: %{public}s', JSON.stringify(err));
      this.statusText = '保存到相册失败（请授予相册权限）';
    }
  }

  // ==================== 切换摄像头 ====================

  private async onSwitchCamera(): Promise<void> {
    this.currentPosition = this.currentPosition === camera.CameraPosition.CAMERA_POSITION_BACK
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
    await this.releaseCamera();
    await this.initCamera();
  }

  private async releaseCamera(): Promise<void> {
    const output: camera.PhotoOutput | undefined = this.photoOutput;
    const session: camera.PhotoSession | undefined = this.photoSession;
    const input: camera.CameraInput | undefined = this.cameraInput;
    try {
      if (output) {
        output.off('photoAvailable', this.photoListener);
      }
      if (session) {
        await session.stop();
        await session.release();
      }
      if (input) {
        await input.close();
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'releaseCamera: %{public}s', JSON.stringify(err));
    } finally {
      this.photoSession = undefined;
      this.photoOutput = undefined;
      this.previewOutput = undefined;
      this.cameraInput = undefined;
      this.cameraManager = undefined;
    }
  }

  // ==================== 水印设置面板 ====================

  @Builder
  watermarkSettingsPanel() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Row() {
          Text('水印设置')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('完成')
            .fontSize(14)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.showSettings = false;
            })
        }
        .width('100%')

        TextInput({ text: this.customText, placeholder: '自定义文字（可留空，仅显示时间戳）' })
          .height(40)
          .fontSize(13)
          .onChange((value: string) => {
            this.customText = value;
          })

        Row() {
          Text('显示时间戳')
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.showTimestamp })
            .onChange((isOn: boolean) => {
              this.showTimestamp = isOn;
            })
        }
        .width('100%')

        Row() {
          Text('显示地理位置')
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.showLocation })
            .onChange((isOn: boolean) => {
              this.showLocation = isOn;
              if (isOn && this.locationText === '') {
                this.refreshLocation();
              }
            })
        }
        .width('100%')

        if (this.showLocation) {
          Row({ space: 8 }) {
            Text(this.locating ? '定位中…' : (this.locationText !== '' ? this.locationText : '未获取到位置'))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('重新定位')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .onClick(() => {
                this.refreshLocation();
              })
          }
          .width('100%')
        }

        Text('样式')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: 8 }) {
          ForEach(this.styleNames, (name: string, index: number) => {
            Button(name)
              .type(ButtonType.Capsule)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor(index === this.styleIndex ? $r('app.color.primary') : '#E9ECEF')
              .fontColor(index === this.styleIndex ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.styleIndex = index;
              })
          }, (name: string) => name)
        }
        .width('100%')

        Text('位置')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Grid() {
          ForEach(this.positionCells, (pos: number) => {
            GridItem() {
              Stack()
                .width('100%')
                .height('100%')
                .backgroundColor(pos === this.positionIndex ? $r('app.color.primary') : '#E9ECEF')
                .borderRadius(4)
            }
            .onClick(() => {
              this.positionIndex = pos;
              this.useCustomPos = false;
            })
          }, (pos: number) => pos.toString())
        }
        .columnsTemplate('1fr 1fr 1fr')
        .rowsTemplate('1fr 1fr 1fr')
        .columnsGap(6)
        .rowsGap(6)
        .width(132)
        .height(84)

        Text('字号')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: 8 }) {
          ForEach(this.sizeNames, (name: string, index: number) => {
            Button(name)
              .type(ButtonType.Capsule)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor(index === this.sizeIndex ? $r('app.color.primary') : '#E9ECEF')
              .fontColor(index === this.sizeIndex ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.sizeIndex = index;
              })
          }, (name: string) => name)
        }
        .width('100%')

        Text('颜色')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: 12 }) {
          ForEach(this.colors, (colorValue: string, index: number) => {
            Stack()
              .width(28)
              .height(28)
              .backgroundColor(colorValue)
              .borderRadius(14)
              .border({
                width: index === this.colorIndex ? 3 : 1,
                color: index === this.colorIndex ? $r('app.color.primary') : '#DDE3E8'
              })
              .onClick(() => {
                this.colorIndex = index;
              })
          }, (colorValue: string) => colorValue)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('透明度')
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
          Slider({ value: this.watermarkOpacity, min: 0.2, max: 1, step: 0.05 })
            .layoutWeight(1)
            .blockColor($r('app.color.primary'))
            .selectedColor($r('app.color.primary'))
            .onChange((value: number) => {
              this.watermarkOpacity = value;
            })
          Text(`${Math.round(this.watermarkOpacity * 100)}%`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width(42)
            .textAlign(TextAlign.End)
        }
        .width('100%')

        Text('提示：关闭面板后，可拖动预览中的水印框自由定位')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Color.White)
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
  }

  // ==================== UI ====================

  build() {
    Stack() {
      Column() {
      // 相机预览
      Stack() {
        XComponent({
          id: 'cameraPreview',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId();
            this.initCamera();
          })

        // 点击对焦的指示圈
        if (this.focusRingVisible) {
          Stack()
            .width(64)
            .height(64)
            .border({ width: 2, color: Color.White, radius: 32 })
            .position({ x: this.focusX - 32, y: this.focusY - 32 })
        }

        // 可拖动的水印定位框（设置面板关闭时显示）
        if (!this.showSettings && this.previewW > 0) {
          Text(this.customText !== '' ? this.customText : '水印')
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#66000000')
            .border({ width: 1, color: '#CCFFFFFF', style: BorderStyle.Dashed, radius: 6 })
            .position({
              x: Math.min(this.previewW - 72, Math.max(0, this.anchorNormX() * this.previewW - 36)),
              y: Math.min(this.previewH - 28, Math.max(0, this.anchorNormY() * this.previewH - 14))
            })
            .gesture(
              PanGesture()
                .onActionStart(() => {
                  this.onWatermarkDragStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onWatermarkDragUpdate(event);
                })
            )
        }

        // 状态提示
        Text(this.statusText)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#66000000')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(8)
          .position({ x: 12, y: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Color.Black)
      .clip(true)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.previewW = newArea.width as number;
        this.previewH = newArea.height as number;
      })
      .onClick((event: ClickEvent) => {
        this.onPreviewTap(event);
      })
      .gesture(
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.baseZoom = this.zoomRatio;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.applyZoom(this.baseZoom * event.scale);
          })
      )

      // 底部操作区
      Column() {
        // 缩放滑杆
        Row({ space: 10 }) {
          Text(`${this.zoomRatio.toFixed(1)}x`)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .width(36)
            .textAlign(TextAlign.End)
          Slider({ value: this.zoomRatio, min: this.minZoom, max: this.maxZoom, step: 0.1 })
            .layoutWeight(1)
            .blockColor($r('app.color.primary'))
            .selectedColor($r('app.color.primary'))
            .trackColor('#DDE3E8')
            .onChange((value: number) => {
              this.applyZoom(value);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 2, bottom: 2 })

        Row() {
          Column() {
            if (this.originalUri !== '') {
              Image(this.originalUri)
                .width(64)
                .height(64)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
            } else {
              Text('原片')
                .width(64)
                .height(64)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .borderRadius(8)
                .backgroundColor('#E9ECEF')
            }
            Text($r('app.string.original_photo'))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          .margin({ right: 20 })

          Column() {
            if (this.watermarkUri !== '') {
              Image(this.watermarkUri)
                .width(64)
                .height(64)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
            } else {
              Text('水印')
                .width(64)
                .height(64)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .borderRadius(8)
                .backgroundColor('#E9ECEF')
            }
            Text($r('app.string.watermark_photo'))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
        }
        .margin({ top: 10, bottom: 10 })

        if (this.watermarkTime !== '') {
          Text(`水印时间戳：${this.watermarkTime}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 8 })
        }

        Row({ space: 8 }) {
          Button($r('app.string.take_photo'))
            .type(ButtonType.Capsule)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .fontSize(14)
            .layoutWeight(1)
            .height(48)
            .enabled(!this.isBusy)
            .onClick(() => this.onCapture())

          Button('水印')
            .type(ButtonType.Capsule)
            .backgroundColor('#E9ECEF')
            .fontColor($r('app.color.text_primary'))
            .fontSize(14)
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.showSettings = true;
            })

          Button($r('app.string.switch_camera'))
            .type(ButtonType.Capsule)
            .backgroundColor('#E9ECEF')
            .fontColor($r('app.color.text_primary'))
            .fontSize(14)
            .layoutWeight(1)
            .height(48)
            .onClick(() => this.onSwitchCamera())

          Button($r('app.string.save_album'))
            .type(ButtonType.Capsule)
            .backgroundColor('#E9ECEF')
            .fontColor($r('app.color.text_primary'))
            .fontSize(14)
            .layoutWeight(1)
            .height(48)
            .onClick(() => this.saveWatermarkToAlbum())
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 12 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))

    if (this.showSettings) {
      this.watermarkSettingsPanel()
    }
    }
    .width('100%')
    .height('100%')
  }
}
