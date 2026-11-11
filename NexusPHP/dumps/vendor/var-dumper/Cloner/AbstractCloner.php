<?php

/*
 * This file is part of the Symfony package.
 *
 * (c) Fabien Potencier <fabien@symfony.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

namespace Nexus\Dumps\VarDumper\Cloner;

use Nexus\Dumps\VarDumper\Caster\Caster;
use Nexus\Dumps\VarDumper\Exception\ThrowingCasterException;

/**
 * AbstractCloner implements a generic caster mechanism for objects and resources.
 *
 * @author Nicolas Grekas <p@tchwork.com>
 */
abstract class AbstractCloner implements ClonerInterface
{
    public static array $defaultCasters = [
        '__PHP_Incomplete_Class' => ['Nexus\Dumps\VarDumper\Caster\Caster', 'castPhpIncompleteClass'],

        'AddressInfo' => ['Nexus\Dumps\VarDumper\Caster\AddressInfoCaster', 'castAddressInfo'],
        'Socket' => ['Nexus\Dumps\VarDumper\Caster\SocketCaster', 'castSocket'],

        'Nexus\Dumps\VarDumper\Caster\CutStub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'castStub'],
        'Nexus\Dumps\VarDumper\Caster\CutArrayStub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'castCutArray'],
        'Nexus\Dumps\VarDumper\Caster\ConstStub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'castStub'],
        'Nexus\Dumps\VarDumper\Caster\EnumStub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'castEnum'],
        'Nexus\Dumps\VarDumper\Caster\ScalarStub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'castScalar'],

        'Fiber' => ['Nexus\Dumps\VarDumper\Caster\FiberCaster', 'castFiber'],

        'Closure' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castClosure'],
        'Generator' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castGenerator'],
        'ReflectionType' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castType'],
        'ReflectionAttribute' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castAttribute'],
        'ReflectionGenerator' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castReflectionGenerator'],
        'ReflectionClass' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castClass'],
        'ReflectionClassConstant' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castClassConstant'],
        'ReflectionFunctionAbstract' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castFunctionAbstract'],
        'ReflectionMethod' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castMethod'],
        'ReflectionParameter' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castParameter'],
        'ReflectionProperty' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castProperty'],
        'ReflectionReference' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castReference'],
        'ReflectionExtension' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castExtension'],
        'ReflectionZendExtension' => ['Nexus\Dumps\VarDumper\Caster\ReflectionCaster', 'castZendExtension'],

        'Doctrine\Common\Persistence\ObjectManager' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Doctrine\Common\Proxy\Proxy' => ['Nexus\Dumps\VarDumper\Caster\DoctrineCaster', 'castCommonProxy'],
        'Doctrine\ORM\Proxy\Proxy' => ['Nexus\Dumps\VarDumper\Caster\DoctrineCaster', 'castOrmProxy'],
        'Doctrine\ORM\PersistentCollection' => ['Nexus\Dumps\VarDumper\Caster\DoctrineCaster', 'castPersistentCollection'],
        'Doctrine\Persistence\ObjectManager' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],

        'DOMException' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castException'],
        'Dom\Exception' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castException'],
        'DOMStringList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMNameList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMImplementation' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castImplementation'],
        'Dom\Implementation' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castImplementation'],
        'DOMImplementationList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMNode' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\Node' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMNameSpaceNode' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMDocument' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDocument'],
        'Dom\XMLDocument' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castXMLDocument'],
        'Dom\HTMLDocument' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castHTMLDocument'],
        'DOMNodeList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\NodeList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMNamedNodeMap' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\DTDNamedNodeMap' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'DOMXPath' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\XPath' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\HTMLCollection' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],
        'Dom\TokenList' => ['Nexus\Dumps\VarDumper\Caster\DOMCaster', 'castDom'],

        'XMLReader' => ['Nexus\Dumps\VarDumper\Caster\XmlReaderCaster', 'castXmlReader'],

        'ErrorException' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castErrorException'],
        'Exception' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castException'],
        'Error' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castError'],
        'Symfony\Bridge\Monolog\Logger' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Symfony\Component\DependencyInjection\ContainerInterface' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Symfony\Component\EventDispatcher\EventDispatcherInterface' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Symfony\Component\HttpClient\AmpHttpClient' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClient'],
        'Symfony\Component\HttpClient\CurlHttpClient' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClient'],
        'Symfony\Component\HttpClient\NativeHttpClient' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClient'],
        'Symfony\Component\HttpClient\Response\AmpResponse' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClientResponse'],
        'Symfony\Component\HttpClient\Response\AmpResponseV4' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClientResponse'],
        'Symfony\Component\HttpClient\Response\AmpResponseV5' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClientResponse'],
        'Symfony\Component\HttpClient\Response\CurlResponse' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClientResponse'],
        'Symfony\Component\HttpClient\Response\NativeResponse' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castHttpClientResponse'],
        'Symfony\Component\HttpFoundation\Request' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castRequest'],
        'Symfony\Component\Uid\Ulid' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castUlid'],
        'Symfony\Component\Uid\Uuid' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castUuid'],
        'Symfony\Component\VarExporter\Internal\LazyObjectState' => ['Nexus\Dumps\VarDumper\Caster\SymfonyCaster', 'castLazyObjectState'],
        'Nexus\Dumps\VarDumper\Exception\ThrowingCasterException' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castThrowingCasterException'],
        'Nexus\Dumps\VarDumper\Caster\TraceStub' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castTraceStub'],
        'Nexus\Dumps\VarDumper\Caster\FrameStub' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castFrameStub'],
        'Nexus\Dumps\VarDumper\Cloner\AbstractCloner' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Symfony\Component\ErrorHandler\Exception\FlattenException' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castFlattenException'],
        'Symfony\Component\ErrorHandler\Exception\SilencedErrorContext' => ['Nexus\Dumps\VarDumper\Caster\ExceptionCaster', 'castSilencedErrorContext'],

        'Imagine\Image\ImageInterface' => ['Nexus\Dumps\VarDumper\Caster\ImagineCaster', 'castImage'],

        'Ramsey\Uuid\UuidInterface' => ['Nexus\Dumps\VarDumper\Caster\UuidCaster', 'castRamseyUuid'],

        'ProxyManager\Proxy\ProxyInterface' => ['Nexus\Dumps\VarDumper\Caster\ProxyManagerCaster', 'castProxy'],
        'PHPUnit_Framework_MockObject_MockObject' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'PHPUnit\Framework\MockObject\MockObject' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'PHPUnit\Framework\MockObject\Stub' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Prophecy\Prophecy\ProphecySubjectInterface' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],
        'Mockery\MockInterface' => ['Nexus\Dumps\VarDumper\Caster\StubCaster', 'cutInternals'],

        'PDO' => ['Nexus\Dumps\VarDumper\Caster\PdoCaster', 'castPdo'],
        'PDOStatement' => ['Nexus\Dumps\VarDumper\Caster\PdoCaster', 'castPdoStatement'],

        'AMQPConnection' => ['Nexus\Dumps\VarDumper\Caster\AmqpCaster', 'castConnection'],
        'AMQPChannel' => ['Nexus\Dumps\VarDumper\Caster\AmqpCaster', 'castChannel'],
        'AMQPQueue' => ['Nexus\Dumps\VarDumper\Caster\AmqpCaster', 'castQueue'],
        'AMQPExchange' => ['Nexus\Dumps\VarDumper\Caster\AmqpCaster', 'castExchange'],
        'AMQPEnvelope' => ['Nexus\Dumps\VarDumper\Caster\AmqpCaster', 'castEnvelope'],

        'ArrayObject' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castArrayObject'],
        'ArrayIterator' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castArrayIterator'],
        'SplDoublyLinkedList' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castDoublyLinkedList'],
        'SplFileInfo' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castFileInfo'],
        'SplFileObject' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castFileObject'],
        'SplHeap' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castHeap'],
        'SplObjectStorage' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castObjectStorage'],
        'SplPriorityQueue' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castHeap'],
        'OuterIterator' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castOuterIterator'],
        'WeakMap' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castWeakMap'],
        'WeakReference' => ['Nexus\Dumps\VarDumper\Caster\SplCaster', 'castWeakReference'],

        'Redis' => ['Nexus\Dumps\VarDumper\Caster\RedisCaster', 'castRedis'],
        'Relay\Relay' => ['Nexus\Dumps\VarDumper\Caster\RedisCaster', 'castRedis'],
        'RedisArray' => ['Nexus\Dumps\VarDumper\Caster\RedisCaster', 'castRedisArray'],
        'RedisCluster' => ['Nexus\Dumps\VarDumper\Caster\RedisCaster', 'castRedisCluster'],

        'DateTimeInterface' => ['Nexus\Dumps\VarDumper\Caster\DateCaster', 'castDateTime'],
        'DateInterval' => ['Nexus\Dumps\VarDumper\Caster\DateCaster', 'castInterval'],
        'DateTimeZone' => ['Nexus\Dumps\VarDumper\Caster\DateCaster', 'castTimeZone'],
        'DatePeriod' => ['Nexus\Dumps\VarDumper\Caster\DateCaster', 'castPeriod'],

        'GMP' => ['Nexus\Dumps\VarDumper\Caster\GmpCaster', 'castGmp'],

        'MessageFormatter' => ['Nexus\Dumps\VarDumper\Caster\IntlCaster', 'castMessageFormatter'],
        'NumberFormatter' => ['Nexus\Dumps\VarDumper\Caster\IntlCaster', 'castNumberFormatter'],
        'IntlTimeZone' => ['Nexus\Dumps\VarDumper\Caster\IntlCaster', 'castIntlTimeZone'],
        'IntlCalendar' => ['Nexus\Dumps\VarDumper\Caster\IntlCaster', 'castIntlCalendar'],
        'IntlDateFormatter' => ['Nexus\Dumps\VarDumper\Caster\IntlCaster', 'castIntlDateFormatter'],

        'Memcached' => ['Nexus\Dumps\VarDumper\Caster\MemcachedCaster', 'castMemcached'],

        'Ds\Collection' => ['Nexus\Dumps\VarDumper\Caster\DsCaster', 'castCollection'],
        'Ds\Map' => ['Nexus\Dumps\VarDumper\Caster\DsCaster', 'castMap'],
        'Ds\Pair' => ['Nexus\Dumps\VarDumper\Caster\DsCaster', 'castPair'],
        'Nexus\Dumps\VarDumper\Caster\DsPairStub' => ['Nexus\Dumps\VarDumper\Caster\DsCaster', 'castPairStub'],

        'mysqli_driver' => ['Nexus\Dumps\VarDumper\Caster\MysqliCaster', 'castMysqliDriver'],

        'CurlHandle' => ['Nexus\Dumps\VarDumper\Caster\CurlCaster', 'castCurl'],

        'Dba\Connection' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castDba'],
        ':dba' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castDba'],
        ':dba persistent' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castDba'],

        'GdImage' => ['Nexus\Dumps\VarDumper\Caster\GdCaster', 'castGd'],

        'SQLite3Result' => ['Nexus\Dumps\VarDumper\Caster\SqliteCaster', 'castSqlite3Result'],

        'PgSql\Lob' => ['Nexus\Dumps\VarDumper\Caster\PgSqlCaster', 'castLargeObject'],
        'PgSql\Connection' => ['Nexus\Dumps\VarDumper\Caster\PgSqlCaster', 'castLink'],
        'PgSql\Result' => ['Nexus\Dumps\VarDumper\Caster\PgSqlCaster', 'castResult'],

        ':process' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castProcess'],
        ':stream' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castStream'],

        'OpenSSLAsymmetricKey' => ['Nexus\Dumps\VarDumper\Caster\OpenSSLCaster', 'castOpensslAsymmetricKey'],
        'OpenSSLCertificateSigningRequest' => ['Nexus\Dumps\VarDumper\Caster\OpenSSLCaster', 'castOpensslCsr'],
        'OpenSSLCertificate' => ['Nexus\Dumps\VarDumper\Caster\OpenSSLCaster', 'castOpensslX509'],

        ':persistent stream' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castStream'],
        ':stream-context' => ['Nexus\Dumps\VarDumper\Caster\ResourceCaster', 'castStreamContext'],

        'XmlParser' => ['Nexus\Dumps\VarDumper\Caster\XmlResourceCaster', 'castXml'],

        'RdKafka' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castRdKafka'],
        'RdKafka\Conf' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castConf'],
        'RdKafka\KafkaConsumer' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castKafkaConsumer'],
        'RdKafka\Metadata\Broker' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castBrokerMetadata'],
        'RdKafka\Metadata\Collection' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castCollectionMetadata'],
        'RdKafka\Metadata\Partition' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castPartitionMetadata'],
        'RdKafka\Metadata\Topic' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castTopicMetadata'],
        'RdKafka\Message' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castMessage'],
        'RdKafka\Topic' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castTopic'],
        'RdKafka\TopicPartition' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castTopicPartition'],
        'RdKafka\TopicConf' => ['Nexus\Dumps\VarDumper\Caster\RdKafkaCaster', 'castTopicConf'],

        'FFI\CData' => ['Nexus\Dumps\VarDumper\Caster\FFICaster', 'castCTypeOrCData'],
        'FFI\CType' => ['Nexus\Dumps\VarDumper\Caster\FFICaster', 'castCTypeOrCData'],
    ];

    protected int $maxItems = 2500;
    protected int $maxString = -1;
    protected int $minDepth = 1;

    /**
     * @var array<string, list<callable>>
     */
    private array $casters = [];

    /**
     * @var callable|null
     */
    private $prevErrorHandler;

    private array $classInfo = [];
    private int $filter = 0;

    /**
     * @param callable[]|null $casters A map of casters
     *
     * @see addCasters
     */
    public function __construct(?array $casters = null)
    {
        $this->addCasters($casters ?? static::$defaultCasters);
    }

    /**
     * Adds casters for resources and objects.
     *
     * Maps resources or object types to a callback.
     * Use types as keys and callable casters as values.
     * Prefix types with `::`,
     * see e.g. self::$defaultCasters.
     *
     * @param array<string, callable> $casters A map of casters
     */
    public function addCasters(array $casters): void
    {
        foreach ($casters as $type => $callback) {
            $this->casters[$type][] = $callback;
        }
    }

    /**
     * Adds default casters for resources and objects.
     *
     * Maps resources or object types to a callback.
     * Use types as keys and callable casters as values.
     * Prefix types with `::`,
     * see e.g. self::$defaultCasters.
     *
     * @param array<string, callable> $casters A map of casters
     */
    public static function addDefaultCasters(array $casters): void
    {
        self::$defaultCasters = [...self::$defaultCasters, ...$casters];
    }

    /**
     * Sets the maximum number of items to clone past the minimum depth in nested structures.
     */
    public function setMaxItems(int $maxItems): void
    {
        $this->maxItems = $maxItems;
    }

    /**
     * Sets the maximum cloned length for strings.
     */
    public function setMaxString(int $maxString): void
    {
        $this->maxString = $maxString;
    }

    /**
     * Sets the minimum tree depth where we are guaranteed to clone all the items.  After this
     * depth is reached, only setMaxItems items will be cloned.
     */
    public function setMinDepth(int $minDepth): void
    {
        $this->minDepth = $minDepth;
    }

    /**
     * Clones a PHP variable.
     *
     * @param int $filter A bit field of Caster::EXCLUDE_* constants
     */
    public function cloneVar(mixed $var, int $filter = 0): Data
    {
        $this->prevErrorHandler = set_error_handler(function ($type, $msg, $file, $line, $context = []) {
            if (\E_RECOVERABLE_ERROR === $type || \E_USER_ERROR === $type) {
                // Cloner never dies
                throw new \ErrorException($msg, 0, $type, $file, $line);
            }

            if ($this->prevErrorHandler) {
                return ($this->prevErrorHandler)($type, $msg, $file, $line, $context);
            }

            return false;
        });
        $this->filter = $filter;

        if ($gc = gc_enabled()) {
            gc_disable();
        }
        try {
            return new Data($this->doClone($var));
        } finally {
            if ($gc) {
                gc_enable();
            }
            restore_error_handler();
            $this->prevErrorHandler = null;
        }
    }

    /**
     * Effectively clones the PHP variable.
     */
    abstract protected function doClone(mixed $var): array;

    /**
     * Casts an object to an array representation.
     *
     * @param bool $isNested True if the object is nested in the dumped structure
     */
    protected function castObject(Stub $stub, bool $isNested): array
    {
        $obj = $stub->value;
        $class = $stub->class;

        if (str_contains($class, "@anonymous\0")) {
            $stub->class = get_debug_type($obj);
        }
        if (isset($this->classInfo[$class])) {
            [$i, $parents, $hasDebugInfo, $fileInfo] = $this->classInfo[$class];
        } else {
            $i = 2;
            $parents = [$class];
            $hasDebugInfo = method_exists($class, '__debugInfo');

            foreach (class_parents($class) as $p) {
                $parents[] = $p;
                ++$i;
            }
            foreach (class_implements($class) as $p) {
                $parents[] = $p;
                ++$i;
            }
            $parents[] = '*';

            $r = new \ReflectionClass($class);
            $fileInfo = $r->isInternal() || $r->isSubclassOf(Stub::class) ? [] : [
                'file' => $r->getFileName(),
                'line' => $r->getStartLine(),
            ];

            $this->classInfo[$class] = [$i, $parents, $hasDebugInfo, $fileInfo];
        }

        $stub->attr += $fileInfo;
        $a = Caster::castObject($obj, $class, $hasDebugInfo, $stub->class);

        try {
            while ($i--) {
                if (!empty($this->casters[$p = $parents[$i]])) {
                    foreach ($this->casters[$p] as $callback) {
                        $a = $callback($obj, $a, $stub, $isNested, $this->filter);
                    }
                }
            }
        } catch (\Exception $e) {
            $a = [(Stub::TYPE_OBJECT === $stub->type ? Caster::PREFIX_VIRTUAL : '').'⚠' => new ThrowingCasterException($e)] + $a;
        }

        return $a;
    }

    /**
     * Casts a resource to an array representation.
     *
     * @param bool $isNested True if the object is nested in the dumped structure
     */
    protected function castResource(Stub $stub, bool $isNested): array
    {
        $a = [];
        $res = $stub->value;
        $type = $stub->class;

        try {
            if (!empty($this->casters[':'.$type])) {
                foreach ($this->casters[':'.$type] as $callback) {
                    $a = $callback($res, $a, $stub, $isNested, $this->filter);
                }
            }
        } catch (\Exception $e) {
            $a = [(Stub::TYPE_OBJECT === $stub->type ? Caster::PREFIX_VIRTUAL : '').'⚠' => new ThrowingCasterException($e)] + $a;
        }

        return $a;
    }
}
